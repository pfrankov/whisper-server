//
//  APIKeyStore.swift
//  WhisperServer
//
//  Keychain-backed API key storage and Vapor auth middleware.
//

import Foundation
import Security
import Vapor
import NIOCore

/// Persistent API key used to authenticate LAN clients.
/// Stored in the macOS Keychain under the app's bundle identifier.
final class APIKeyStore {
    static let shared = APIKeyStore()

    enum StoreError: LocalizedError {
        case keychainFailure(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychainFailure(let status):
                return "Keychain operation failed (status \(status))."
            }
        }
    }

    private let service: String
    private let account = "whisper-api-key"

    /// In-memory cache so middleware doesn't hit `securityd` on every LAN request.
    /// Populated lazily on first read; refreshed on every successful `save(_:)`.
    private let cacheLock = NSLock()
    private var cachedToken: String?

    private init() {
        self.service = Bundle.main.bundleIdentifier ?? "pfrankov.WhisperServer"
    }

    // MARK: - Public API

    /// Returns the current key, generating and persisting one on first access if needed.
    /// Throws if the Keychain write fails so callers can surface the error to the user.
    @discardableResult
    func ensureExists() throws -> String {
        if let existing = current() { return existing }
        let fresh = Self.generateToken()
        try save(fresh)
        return fresh
    }

    /// Returns the current key if one is stored, otherwise nil.
    /// Reads from an in-memory cache after the first Keychain fetch so
    /// hot request paths don't pay the synchronous IPC round-trip every time.
    func current() -> String? {
        cacheLock.lock()
        if let cached = cachedToken {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let token = readFromKeychain() else { return nil }

        cacheLock.lock()
        cachedToken = token
        cacheLock.unlock()
        return token
    }

    private func readFromKeychain() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    /// Generates and stores a new key, replacing any existing one.
    /// Throws if the Keychain write fails, leaving the previously stored key untouched.
    @discardableResult
    func regenerate() throws -> String {
        let fresh = Self.generateToken()
        try save(fresh)
        return fresh
    }

    // MARK: - Private

    private func baseQuery() -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func save(_ token: String) throws {
        let data = Data(token.utf8)
        var query = baseQuery()

        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("❌ Failed to store API key in Keychain (status \(addStatus))")
                throw StoreError.keychainFailure(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            print("❌ Failed to update API key in Keychain (status \(updateStatus))")
            throw StoreError.keychainFailure(updateStatus)
        }

        // Keychain write succeeded — refresh the in-memory cache so the next
        // middleware read sees the new token without a Keychain round-trip.
        cacheLock.lock()
        cachedToken = token
        cacheLock.unlock()
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fallback: Swift's SystemRandomNumberGenerator (backed by arc4random
            // on Darwin) is cryptographically suitable as a last-resort source.
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "ws-\(hex)"
    }
}

// MARK: - Vapor Middleware

/// Enforces Bearer token authentication on non-loopback requests when
/// `SettingsStore.requireAPIKey` is on. Loopback clients (127.0.0.1 / ::1)
/// always bypass. When LAN exposure is off the server binds to `localhost`
/// only, so all inbound traffic is loopback and this middleware naturally
/// no-ops regardless of the `requireAPIKey` flag.
struct APIKeyAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        if Self.isLoopback(request.remoteAddress) {
            return try await next.respond(to: request)
        }

        // Thread-safe read: SettingsStore routes the value through UserDefaults,
        // which we can safely query from the NIO event loop without hopping to main.
        guard SettingsStore.isAPIKeyRequired else {
            return try await next.respond(to: request)
        }

        // Reject obviously oversized tokens up front so an attacker cannot
        // push arbitrarily large `Authorization` headers through the full
        // constant-time compare and waste event-loop cycles. Our tokens are
        // 67 chars (`ws-` + 64 hex); 128 is a comfortable upper bound.
        guard let bearer = request.headers.bearerAuthorization,
              bearer.token.utf8.count <= 128,
              let expected = APIKeyStore.shared.current(),
              Self.constantTimeEqual(bearer.token, expected) else {
            throw Abort(.unauthorized, reason: "Missing or invalid API key")
        }

        return try await next.respond(to: request)
    }

    private static func isLoopback(_ address: SocketAddress?) -> Bool {
        guard let ip = address?.ipAddress else { return false }
        if ip == "127.0.0.1" || ip == "::1" || ip == "::ffff:127.0.0.1" { return true }
        return ip.hasPrefix("127.")
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        // Iterate the UTF-8 views directly — no `Array(...)` copy, so the NIO
        // event loop doesn't take an attacker-controlled heap allocation per
        // request. Fold the length difference into `diff` and walk both views
        // up to `max(count)` so unequal lengths don't short-circuit the compare.
        let lhsBytes = lhs.utf8
        let rhsBytes = rhs.utf8
        let maxCount = max(lhsBytes.count, rhsBytes.count)
        var diff = UInt(lhsBytes.count ^ rhsBytes.count)
        var lhsIter = lhsBytes.makeIterator()
        var rhsIter = rhsBytes.makeIterator()
        for _ in 0..<maxCount {
            let lhsByte = UInt(lhsIter.next() ?? 0)
            let rhsByte = UInt(rhsIter.next() ?? 0)
            diff |= lhsByte ^ rhsByte
        }
        return diff == 0
    }
}
