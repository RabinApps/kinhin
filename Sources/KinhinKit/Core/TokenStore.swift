import Foundation
import Security
import Synchronization

/// Stores forge tokens (GitHub PAT, Gitea access token) in the login Keychain
/// so neither the config file nor logs ever contain the secret.
public enum KeychainTokenStore {
    public static let account = "github-pat"
    /// Account name for a forge's token ("github-pat", "gitea-pat", …).
    public static func account(for forge: ForgeID) -> String {
        "\(forge.rawValue)-pat"
    }

    /// Name of the account that legacy single-account configs map to: the
    /// forge's own id ("github", "gitea"). Its token keeps the pre-multi-account
    /// Keychain item, so existing installs need no migration.
    public static func legacyAccountName(for forge: ForgeID) -> String { forge.rawValue }

    /// Keychain account for a named forge account. The legacy names resolve to
    /// the original items; any other name gets its own ("github-pat:work").
    public static func account(for forge: ForgeID, name: String) -> String {
        name == legacyAccountName(for: forge) ? account(for: forge) : "\(account(for: forge)):\(name)"
    }

    /// Tests point this at a throwaway service so they never read, overwrite,
    /// or delete the developer's real token. While set, the legacy-service
    /// migration is off too (it would touch the real legacy item).
    static var serviceOverride: String? {
        get { serviceOverrideStorage.withLock { $0 } }
        set { serviceOverrideStorage.withLock { $0 = newValue } }
    }
    private static let serviceOverrideStorage = Mutex<String?>(nil)
    static var service: String { serviceOverride ?? Paths.keychainService }

    /// Keychain service name used by the pre-rename build ("Orchard").
    /// Load falls back to it once and re-saves under the current service,
    /// so tokens stored before the rename migrate transparently.
    static let legacyService = "com.orchard.runner"

    public enum TokenError: LocalizedError {
        case unhandled(OSStatus)
        /// The item exists (or may exist) but the Keychain refused to hand it
        /// over: a denied prompt, a locked keychain, an item another build owns.
        /// Distinct from "no token stored" so callers never send the user back
        /// to setup for a token they already saved.
        case unreadable(account: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .unhandled(let status): return "Keychain error (OSStatus \(status))"
            case .unreadable(let account, let reason):
                return "couldn't read the \(account) token from the Keychain: \(reason)"
            }
        }
    }

    public static func save(_ token: String, forge: ForgeID = .github) throws {
        try save(token, forge: forge, name: legacyAccountName(for: forge))
    }

    public static func save(_ token: String, forge: ForgeID, name: String) throws {
        if mode == .environment {
            saveForSession(token, name: name)
            return
        }
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: forge, name: name),
        ]
        // Re-stating the accessibility class on update moves items stored by
        // older builds (plain AfterFirstUnlock, included in backups) to the
        // this-device-only class.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw TokenError.unhandled(status) }
        } else if update != errSecSuccess {
            throw TokenError.unhandled(update)
        }
    }

    /// Legacy GitHub-only overload (existing call sites).
    public static func save(_ token: String) throws {
        try save(token, forge: .github)
    }

    /// The stored token, or nil when none is stored. Throws
    /// `TokenError.unreadable` when the Keychain fails for any other reason.
    public static func load(forge: ForgeID = .github) throws -> String? {
        try load(forge: forge, name: legacyAccountName(for: forge))
    }

    public static func load(forge: ForgeID, name: String) throws -> String? {
        if mode == .environment { return environmentToken(name: name) }
        let account = account(for: forge, name: name)
        if let token = try load(from: service, account: account) {
            return token
        }
        // One-time legacy migration: re-save under the current service, then
        // drop the pre-rename item so it never lingers in the Keychain.
        guard serviceOverride == nil,
            let legacy = try load(from: legacyService, account: account)
        else { return nil }
        do {
            try save(legacy, forge: forge, name: name)
            delete(from: legacyService, account: account)
        } catch {
            // Keep the legacy item so the token is not lost; retry next load.
            Log.warn("keychain", "legacy token migration failed: \(error.localizedDescription)")
        }
        return legacy
    }

    private static func load(from service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            Log.warn("keychain", "couldn't read \(account) token from the Keychain: \(reason) (OSStatus \(status))")
            throw TokenError.unreadable(account: account, reason: "\(reason) (OSStatus \(status))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func delete(forge: ForgeID = .github) {
        delete(forge: forge, name: legacyAccountName(for: forge))
    }

    public static func delete(forge: ForgeID, name: String) {
        if mode == .environment {
            forgetSessionToken(name: name)
            return
        }
        delete(from: service, account: account(for: forge, name: name))
    }

    private static func delete(from service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Dev-only environment token source

extension KeychainTokenStore {
    /// Where tokens live. `environment` exists only in DEBUG builds: it lets a
    /// developer run without ever touching (or being prompted by) the Keychain.
    enum Mode: Equatable {
        case keychain
        case environment
    }

    /// The env var that turns the environment source on (DEBUG builds only).
    static let modeVariable = "KINHIN_TOKEN_STORE"

    /// The variable an account's token is read from: `KINHIN_TOKEN_<NAME>`,
    /// upper-cased with every non-alphanumeric character as `_`
    /// (`github` → `KINHIN_TOKEN_GITHUB`, `ci-bot` → `KINHIN_TOKEN_CI_BOT`).
    public static func environmentVariableName(for accountName: String) -> String {
        let normalized = accountName.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }
        return "KINHIN_TOKEN_" + String(normalized)
    }

    #if DEBUG
        /// Test seam: the process environment the environment source reads.
        static var environmentProvider: @Sendable () -> [String: String] {
            get { environmentProviderStorage.withLock { $0 } }
            set { environmentProviderStorage.withLock { $0 = newValue } }
        }
        private static let environmentProviderStorage = Mutex<@Sendable () -> [String: String]>({
            ProcessInfo.processInfo.environment
        })
        /// Tokens entered in the UI/CLI this process; never persisted.
        private static let sessionTokens = Mutex<[String: String]>([:])
        private static let announcedMode = Mutex(false)
        private static let warnedAboutSave = Mutex(false)

        static var mode: Mode {
            // Tests that point the store at a throwaway Keychain service keep
            // using it, even when a developer exports the variable globally.
            guard serviceOverride == nil, environmentProvider()[modeVariable] == "env" else { return .keychain }
            let first = announcedMode.withLock { announced -> Bool in
                defer { announced = true }
                return !announced
            }
            if first {
                Log.info(
                    "keychain",
                    "token store: environment (\(modeVariable)=env, debug build) — the Keychain is not used")
            }
            return .environment
        }

        static func environmentToken(name: String) -> String? {
            let variable = environmentVariableName(for: name)
            if let session = sessionTokens.withLock({ $0[variable] }) { return session }
            let value = environmentProvider()[variable]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }

        static func saveForSession(_ token: String, name: String) {
            sessionTokens.withLock { $0[environmentVariableName(for: name)] = token }
            let first = warnedAboutSave.withLock { warned -> Bool in
                defer { warned = true }
                return !warned
            }
            if first {
                Log.warn(
                    "keychain",
                    "environment token mode: tokens entered now last for this run only — set the env var to keep one")
            }
        }

        static func forgetSessionToken(name: String) {
            _ = sessionTokens.withLock { $0.removeValue(forKey: environmentVariableName(for: name)) }
        }

        /// Clears per-process state (tests).
        static func resetEnvironmentModeForTesting() {
            sessionTokens.withLock { $0.removeAll() }
            announcedMode.withLock { $0 = false }
            warnedAboutSave.withLock { $0 = false }
            environmentProvider = { ProcessInfo.processInfo.environment }
        }
    #else
        /// Release builds always use the Keychain.
        static var mode: Mode { .keychain }
        static func environmentToken(name: String) -> String? { nil }
        static func saveForSession(_ token: String, name: String) {}
        static func forgetSessionToken(name: String) {}
    #endif
}

/// Caches the short-lived (1 h) runner registration token, refreshing it
/// `refreshMargin` before expiry. Thread-safe. Under concurrent contention it
/// may fetch twice — harmless against the GitHub API.
final class RegistrationTokenCache: Sendable {
    private struct Entry: Sendable {
        let token: String
        let expiresAt: Date
    }

    private let entry = Mutex<Entry?>(nil)
    private let ttl: TimeInterval
    private let refreshMargin: TimeInterval

    init(ttl: TimeInterval = 50 * 60, refreshMargin: TimeInterval = 5 * 60) {
        self.ttl = ttl
        self.refreshMargin = refreshMargin
    }

    /// Returns the cached token while fresh; otherwise invokes `fetch`.
    func token(fetch: () async throws -> String) async throws -> String {
        let now = Date()
        if let current = entry.withLock({ $0 }),
            now < current.expiresAt.addingTimeInterval(-refreshMargin)
        {
            return current.token
        }
        let fresh = try await fetch()
        let expiry = now.addingTimeInterval(ttl)
        entry.withLock { $0 = Entry(token: fresh, expiresAt: expiry) }
        return fresh
    }

    func invalidate() {
        entry.withLock { $0 = nil }
    }
}
