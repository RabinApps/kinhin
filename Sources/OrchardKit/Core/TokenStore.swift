import Foundation
import Security

/// Stores forge tokens (GitHub PAT, Gitea access token) in the login Keychain
/// so neither the config file nor logs ever contain the secret.
public enum KeychainTokenStore {
    public static let account = "github-pat"
    /// Account name for a forge's token ("github-pat", "gitea-pat").
    public static func account(for forge: ForgeID) -> String {
        forge == .github ? "github-pat" : "gitea-pat"
    }

    public enum TokenError: LocalizedError {
        case unhandled(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unhandled(let status): return "Keychain error (OSStatus \(status))"
            }
        }
    }

    public static func save(_ token: String, forge: ForgeID = .github) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Paths.keychainService,
            kSecAttrAccount as String: account(for: forge),
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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

    public static func load(forge: ForgeID = .github) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Paths.keychainService,
            kSecAttrAccount as String: account(for: forge),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func delete(forge: ForgeID = .github) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Paths.keychainService,
            kSecAttrAccount as String: account(for: forge),
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Caches the short-lived (1 h) runner registration token, refreshing it
/// `refreshMargin` before expiry. Thread-safe. Under concurrent contention it
/// may fetch twice — harmless against the GitHub API.
public final class RegistrationTokenCache: Sendable {
    private struct Entry: Sendable {
        let token: String
        let expiresAt: Date
    }

    private let entry = Mutex<Box<Entry?>>(Box(nil))
    private let ttl: TimeInterval
    private let refreshMargin: TimeInterval

    public init(ttl: TimeInterval = 50 * 60, refreshMargin: TimeInterval = 5 * 60) {
        self.ttl = ttl
        self.refreshMargin = refreshMargin
    }

    /// Returns the cached token while fresh; otherwise invokes `fetch`.
    public func token(fetch: () async throws -> String) async throws -> String {
        let now = Date()
        if let current = entry.withLock({ $0.value }),
           now < current.expiresAt.addingTimeInterval(-refreshMargin) {
            return current.token
        }
        let fresh = try await fetch()
        let expiry = now.addingTimeInterval(ttl)
        entry.withLock { $0.value = Entry(token: fresh, expiresAt: expiry) }
        return fresh
    }

    public func invalidate() {
        entry.withLock { $0.value = nil }
    }
}
