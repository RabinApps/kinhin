import Foundation

/// One forge account: a scope on a forge, served with its own token.
///
/// The legacy `repo:` and `gitea:` sections are the two built-in accounts
/// named `github` and `gitea` (see `KinhinConfig.allAccounts`); every entry
/// of the `accounts:` list is an additional one. Tokens live in the Keychain,
/// keyed by forge + account name (see `KeychainTokenStore`).
public struct AccountConfig: Sendable, Equatable, Codable {
    public var name: String
    public var forge: ForgeID
    /// "owner/name" (one repository) or an org name.
    public var scope: String
    /// Gitea instance base URL. Required for Gitea, unused for GitHub.
    public var instance: String?
    /// Gitea job labels (nil → the host-mode default). Unused for GitHub.
    public var labels: [String]?

    public init(name: String, forge: ForgeID, scope: String, instance: String? = nil, labels: [String]? = nil) {
        self.name = name
        self.forge = forge
        self.scope = scope
        self.instance = instance
        self.labels = labels
    }

    enum CodingKeys: String, CodingKey {
        case name, forge, scope, instance, labels
    }

    /// Names reserved for the legacy `repo:` / `gitea:` sections.
    public static let reservedNames: Set<String> = Set(ForgeID.allCases.map(\.rawValue))

    /// Account names are used in Keychain items and CLI flags: keep them tame.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 32 else { return false }
        let lower = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        return lower.contains(first)
            && name.unicodeScalars.allSatisfy { lower.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// `owner/name` or a bare org name.
    static func isValidScope(_ scope: String) -> Bool {
        let segments = scope.split(separator: "/", omittingEmptySubsequences: false)
        return (1...2).contains(segments.count) && segments.allSatisfy { !$0.isEmpty }
    }
}

extension KinhinConfig {
    /// Every account this config serves: the legacy `github` / `gitea`
    /// accounts (when configured) followed by the explicit `accounts:` list.
    public var allAccounts: [AccountConfig] {
        var result: [AccountConfig] = []
        if githubEnabled {
            result.append(AccountConfig(name: ForgeID.github.rawValue, forge: .github, scope: repo))
        }
        if let gitea {
            result.append(
                AccountConfig(
                    name: ForgeID.gitea.rawValue, forge: .gitea, scope: gitea.scope, instance: gitea.instance,
                    labels: gitea.labels))
        }
        return result + accounts
    }
}
