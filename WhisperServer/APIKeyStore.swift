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

    private let service: String
    private let account = "whisper-api-key"

    private init() {
        self.service = Bundle.main.bundleIdentifier ?? "pfrankov.WhisperServer"
    }

    // MARK: - Public API

    /// Returns the current key, generating and persisting one on first access if needed.
    @discardableResult
    func ensureExists() -> String {
        if let existing = current() { return existing }
        let fresh = Self.generateToken()
        save(fresh)
        return fresh
    }

    /// Returns the current key if one is stored, otherwise nil.
    func current() -> String? {
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
    @discardableResult
    func regenerate() -> String {
        let fresh = Self.generateToken()
        save(fresh)
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

    private func save(_ token: String) {
        let data = Data(token.utf8)
        var query = baseQuery()

        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("❌ Failed to store API key in Keychain (status \(addStatus))")
            }
        } else if updateStatus != errSecSuccess {
            print("❌ Failed to update API key in Keychain (status \(updateStatus))")
        }
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fallback: RNG pulled from /dev/urandom via arc4random_buf
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "ws-\(hex)"
    }
}

// MARK: - Vapor Middleware

/// Enforces Bearer token authentication when LAN exposure AND key-requirement are both on.
/// Loopback clients (127.0.0.1, ::1) are always allowed through so local dev is unaffected.
struct APIKeyAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        if Self.isLoopback(request.remoteAddress) {
            return try await next.respond(to: request)
        }

        guard SettingsStore.shared.requireAPIKey else {
            return try await next.respond(to: request)
        }

        guard let bearer = request.headers.bearerAuthorization,
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
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for index in left.indices { diff |= left[index] ^ right[index] }
        return diff == 0
    }
}
