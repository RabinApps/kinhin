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
    /// Instance base URL. Required for Gitea/Forgejo and Azure DevOps (the
    /// organization URL), optional for GitLab (gitlab.com when absent) and
    /// GitHub (nil = github.com; a GHES host or GHEC data-residency host
    /// otherwise). Unused for Buildkite and Bitbucket (hosted only).
    public var instance: String?
    /// Job labels: Gitea-family `runs-on` labels (nil → the host-mode
    /// default), GitLab tags (nil → the top-level `labels:`) or Buildkite
    /// agent tags, `key=value` (nil → `queue=kinhin`), or Azure DevOps agent
    /// capabilities that pipelines demand (nil → none: the pool is kinhin's
    /// alone). Unused for GitHub.
    public var labels: [String]?
    /// Instance base URL. Required for Gitea/Forgejo and Azure DevOps (the
    /// organization URL), optional for GitLab (gitlab.com when absent) and
    /// GitHub (nil = github.com; a GHES host or GHEC data-residency host
    /// otherwise). Unused for Buildkite and Bitbucket (hosted only).
    public var allowInsecureHTTP: Bool?
    /// Opt-in GitHub Runner Scale Set mode for this account. Absent means the
    /// classic REST workflow-runs poller (today's default); present enables the
    /// actions/scaleset-style message API path.
    public var scaleSet: ScaleSetConfig?

    public init(
        name: String, forge: ForgeID, scope: String, instance: String? = nil, labels: [String]? = nil,
        allowInsecureHTTP: Bool? = nil, scaleSet: ScaleSetConfig? = nil
    ) {
        self.name = name
        self.forge = forge
        self.scope = scope
        self.instance = instance
        self.labels = labels
        self.allowInsecureHTTP = allowInsecureHTTP
        self.scaleSet = scaleSet
    }

    /// True when this account's instance is a plain `http://` URL to a host
    /// other than loopback, so its access token crosses the network in cleartext.
    public var sendsTokenOverPlainHTTP: Bool {
        guard let instance, let url = URL(string: instance), url.scheme?.lowercased() == "http" else { return false }
        return !ForgeHTTP.isLoopback(host: url.host ?? "")
    }

    enum CodingKeys: String, CodingKey {
        case name, forge, scope, instance, labels
        case allowInsecureHTTP = "allow_insecure_http"
        case scaleSet = "scale_set"
    }

    /// Names the app treats specially (the primary per-forge cards). GitLab
    /// has none, so "gitlab" is an ordinary account name.
    public static let reservedNames: Set<String> = [
        ForgeID.github.rawValue, ForgeID.gitea.rawValue, ForgeID.forgejo.rawValue,
    ]

    /// Opt-in GitHub Runner Scale Set config for one account.
    public struct ScaleSetConfig: Sendable, Equatable, Codable {
        /// Base name for the scale set. Per-pool suffixes are derived from it
        /// (for example `kinhin`, `kinhin-container`, `kinhin-docker`).
        public var name: String
        /// Runner group to create/use; nil falls back to the default group.
        public var runnerGroup: String?

        public init(name: String, runnerGroup: String? = nil) {
            self.name = name
            self.runnerGroup = runnerGroup
        }

        enum CodingKeys: String, CodingKey {
            case name
            case runnerGroup = "runner_group"
        }

        /// A scale-set name must be a valid `runs-on` label segment the fleet
        /// can request and GitHub can use as a label.
        public static func isValidName(_ name: String) -> Bool {
            return AccountConfig.isValidScope(name)
        }
    }

    /// True when this account is configured for GitHub Runner Scale Set mode.
    public var isScaleSet: Bool { scaleSet != nil }

    /// Account names are used in Keychain items and CLI flags: keep them tame.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 32 else { return false }
        let lower = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        return lower.contains(first)
            && name.unicodeScalars.allSatisfy { lower.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// A scope the forge accepts: GitLab paths nest (`group/sub/project`),
    /// Buildkite takes `org/cluster`, Azure DevOps an agent pool name,
    /// Bitbucket a workspace or `workspace/repo`, the others `owner/name` or
    /// a bare org.
    static func isValidScope(_ scope: String, forge: ForgeID) -> Bool {
        switch forge {
        case .gitlab: return GitLabCredentials.isValidScope(scope)
        case .buildkite: return BuildkiteCredentials.isValidScope(scope)
        case .azuredevops: return AzureDevOpsCredentials.isValidScope(scope)
        case .bitbucket: return BitbucketCredentials.isValidScope(scope)
        case .github, .gitea, .forgejo: return isValidScope(scope)
        }
    }

    /// Scale sets require ephemeral runners (scale-set runners are one-job
    /// ephemeral by design).
    public var requiresEphemeral: Bool { true }

    /// `owner/name` or a bare org name.
    static func isValidScope(_ scope: String) -> Bool {
        let segments = scope.split(separator: "/", omittingEmptySubsequences: false)
        // The characters forges allow in owner and repo names. Scopes are spliced into API paths, so
        // `?`, `#`, `%` and `..` must never get through.
        return (1...2).contains(segments.count)
            && segments.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
                    && $0.range(of: #"^[A-Za-z0-9._-]+\z"#, options: .regularExpression) != nil
            }
    }
}

extension AccountConfig {
    /// True when the scope names one repository (`owner/name`) on a forge whose
    /// runners register per repository. Orgs, groups, Buildkite clusters and Azure
    /// pools cover many repositories.
    var isSingleRepositoryScope: Bool {
        switch forge {
        case .github, .gitea, .forgejo, .bitbucket:
            return scope.split(separator: "/", omittingEmptySubsequences: false).count == 2
        case .gitlab:
            // GitLab paths nest; only a project path (group/project) names one project,
            // and it is indistinguishable from a subgroup, so require two or more segments.
            return scope.split(separator: "/").count >= 2
        case .buildkite, .azuredevops:
            return false
        }
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
