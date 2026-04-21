//
//  SettingsStore.swift
//  WhisperServer
//
//  Persistent user preferences (launch at login, LAN exposure)
//

import Foundation
import ServiceManagement
import Darwin

/// Source of truth for WhisperServer user preferences.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let launchAtLogin = "launchAtLogin"
        static let exposeOnLAN = "exposeOnLAN"
        static let lanWarningShown = "lanWarningShown"
        static let requireAPIKey = "requireAPIKey"
        static let apiKeyWarningShown = "apiKeyWarningShown"
    }

    // MARK: - Stored Settings

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            guard !isSyncing else { return }
            applyLaunchAtLogin()
        }
    }

    @Published var exposeOnLAN: Bool {
        didSet { UserDefaults.standard.set(exposeOnLAN, forKey: Keys.exposeOnLAN) }
    }

    @Published var requireAPIKey: Bool {
        didSet { UserDefaults.standard.set(requireAPIKey, forKey: Keys.requireAPIKey) }
    }

    /// Thread-safe snapshot of the `requireAPIKey` flag for readers outside the
    /// main actor (e.g. Vapor middleware on NIO event loops). `UserDefaults` is
    /// documented as thread-safe, and `didSet` above writes to it before any
    /// @Published observer fires — so there's no window where the value drifts.
    static var isAPIKeyRequired: Bool {
        UserDefaults.standard.bool(forKey: Keys.requireAPIKey)
    }

    var lanWarningShown: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.lanWarningShown) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lanWarningShown) }
    }

    var apiKeyWarningShown: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.apiKeyWarningShown) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.apiKeyWarningShown) }
    }

    // MARK: - Derived Values

    /// Hostname to bind the HTTP server on.
    var serverHostname: String { exposeOnLAN ? "0.0.0.0" : "localhost" }

    // MARK: - Private

    /// Suppresses side effects while we sync published values from the system.
    private var isSyncing = false

    private init() {
        self.launchAtLogin = UserDefaults.standard.bool(forKey: Keys.launchAtLogin)
        self.exposeOnLAN = UserDefaults.standard.bool(forKey: Keys.exposeOnLAN)
        self.requireAPIKey = UserDefaults.standard.bool(forKey: Keys.requireAPIKey)
        syncLaunchAtLoginFromSystem()
    }

    /// Registers or unregisters the main app as a login item via SMAppService.
    private func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            print("❌ Failed to toggle launch-at-login: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSyncing = true
                self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
                self.isSyncing = false
            }
        }
    }

    /// Reconciles our cached state with the system's actual SMAppService status
    /// (the user may have toggled the login item via System Settings).
    private func syncLaunchAtLoginFromSystem() {
        let systemEnabled = (SMAppService.mainApp.status == .enabled)
        if launchAtLogin != systemEnabled {
            isSyncing = true
            launchAtLogin = systemEnabled
            isSyncing = false
        }
    }
}

// MARK: - Network Utility

enum NetworkUtility {
    /// Returns the machine's primary non-loopback IPv4 address (prefers en0/en1).
    static func primaryLocalIPv4() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var fallback: String?
        var iter: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = iter {
            defer { iter = ptr.pointee.ifa_next }

            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let ip = String(cString: host)
            let name = String(cString: ptr.pointee.ifa_name)
            if name == "en0" || name == "en1" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }
}
