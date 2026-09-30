import Foundation

/// One forge account: a scope on a forge, served with its own token.
///
/// Every forge this config serves is an entry of the `accounts:` list. The
/// entry named "github" ("gitea", "forgejo") maps to the original Keychain
/// item and the app's primary card; other entries are additional accounts
/// keyed by name (see `KeychainTokenStore`).
public struct AccountConfig: Sendable, Equatable, Codable {
    public var name: String
    public var forge: ForgeID
    /// "owner/name" (one repository) or an org name.
    public var scope: String
    /// Instance base URL. Required for Gitea/Forgejo, optional for GitLab
    /// (gitlab.com when absent), unused for GitHub and Buildkite.
    public var instance: String?
    /// Job labels: Gitea-family `runs-on` labels (nil → the host-mode
    /// default), GitLab tags (nil → the top-level `labels:`) or Buildkite
    /// agent tags, `key=value` (nil → `queue=kinhin`). Unused for GitHub.
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

    /// Names the app treats specially (the primary per-forge cards). GitLab
    /// has none, so "gitlab" is an ordinary account name.
    public static let reservedNames: Set<String> = [
        ForgeID.github.rawValue, ForgeID.gitea.rawValue, ForgeID.forgejo.rawValue,
    ]

    /// Account names are used in Keychain items and CLI flags: keep them tame.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 32 else { return false }
        let lower = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        return lower.contains(first)
            && name.unicodeScalars.allSatisfy { lower.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// A scope the forge accepts: GitLab paths nest (`group/sub/project`),
    /// Buildkite takes `org/cluster`, the others `owner/name` or a bare org.
    static func isValidScope(_ scope: String, forge: ForgeID) -> Bool {
        switch forge {
        case .gitlab: return GitLabCredentials.isValidScope(scope)
        case .buildkite: return BuildkiteCredentials.isValidScope(scope)
        case .github, .gitea, .forgejo: return isValidScope(scope)
        }
    }

    /// `owner/name` or a bare org name.
    static func isValidScope(_ scope: String) -> Bool {
        let segments = scope.split(separator: "/", omittingEmptySubsequences: false)
        return (1...2).contains(segments.count) && segments.allSatisfy { !$0.isEmpty }
    }
}

extension KinhinConfig {
    /// Every account this config serves. (Kept as a named view: engine and
    /// CLI iterate it; under the accounts-only schema it is just `accounts`.)
    public var allAccounts: [AccountConfig] { accounts }
}

/// Token presence across a forge's accounts — what image baking gates on: an
/// agent is baked in when *any* account of its platform can use it.
public enum AccountTokens {
    public static func anyStored(
        for forge: ForgeID,
        config: KinhinConfig? = loadedConfig(),
        load: (ForgeID, String) throws -> String? = { try KeychainTokenStore.load(forge: $0, name: $1) }
    ) throws -> Bool {
        return try (config?.accounts ?? []).contains { try $0.forge == forge && load($0.forge, $0.name) != nil }
    }

    /// The on-disk config when there is a valid one; a broken file is logged
    /// (the image step then falls back to the legacy tokens alone).
    public static func loadedConfig() -> KinhinConfig? {
        guard FileManager.default.fileExists(atPath: Paths.config.path) else { return nil }
        do {
            return try ConfigLoader.load()
        } catch {
            Log.warn("config", "could not read accounts for token detection: \(error.localizedDescription)")
            return nil
        }
    }
}
