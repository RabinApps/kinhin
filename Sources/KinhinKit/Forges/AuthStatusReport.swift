import Foundation

/// Machine-readable `kinhin auth status --json` contract: stored-token state
/// for every forge in one document. Static by design — no network probes —
/// so scripts get a fast, deterministic answer; live validation stays in the
/// human `auth status` output and the app's token settings form.
/// Field names are a stable API: add, never rename.
public struct AuthStatusReport: Codable, Equatable, Sendable {
    public struct Forge: Codable, Equatable, Sendable {
        /// "github" | "gitea" (the ForgeID raw value).
        public let id: String
        /// A token is present in the Keychain.
        public let stored: Bool
        /// First four characters of the stored token, or null — the same
        /// masking the human `auth status` prints. Never the full secret.
        public let prefix: String?
        /// The forge has a usable config section/scope (GitHub: non-empty
        /// repo; Gitea: a `gitea:` block).
        public let configured: Bool
        /// GitHub: repo/org scope. Gitea: scope. Null when unconfigured.
        public let scope: String?
        /// Gitea instance URL; null otherwise.
        public let instance: String?
        /// Human-readable one-liner (contains no secret beyond `prefix`).
        public let detail: String

        public init(
            id: String, stored: Bool, prefix: String?, configured: Bool,
            scope: String?, instance: String?, detail: String
        ) {
            self.id = id
            self.stored = stored
            self.prefix = prefix
            self.configured = configured
            self.scope = scope
            self.instance = instance
            self.detail = detail
        }
    }

    /// One entry per forge, in `ForgeID.allCases` order (github first).
    public let forges: [Forge]
    /// True when every forge the fleet actually needs has a stored token:
    /// GitHub must be stored *and* have a scope; Gitea only when configured.
    /// Mirrors the CLI's exit code for `auth status --json`.
    public let allGood: Bool

    public init(forges: [Forge], allGood: Bool) {
        self.forges = forges
        self.allGood = allGood
    }
}

/// Builds AuthStatusReport from injected state. `load` stands in for the
/// Keychain so tests stay hermetic; `.live` passes `KeychainTokenStore.load`.
public enum AuthStatusReporter {
    public static func report(config: KinhinConfig?, load: (ForgeID) -> String?) -> AuthStatusReport {
        let githubToken = load(.github)
        let repo = config?.repo
        // The starter placeholder repo means "no GitHub" (Gitea-only configs).
        let githubConfigured = !(repo ?? "").isEmpty && repo != ConfigLoader.templateRepo

        let giteaToken = load(.gitea)
        let gitea = config?.gitea

        var forges: [AuthStatusReport.Forge] = []
        forges.append(
            AuthStatusReport.Forge(
                id: ForgeID.github.rawValue,
                stored: githubToken != nil,
                prefix: githubToken.map { String($0.prefix(4)) },
                configured: githubConfigured,
                scope: githubConfigured ? repo : nil,
                instance: nil,
                detail: githubDetail(token: githubToken, scope: repo)
            ))
        forges.append(
            AuthStatusReport.Forge(
                id: ForgeID.gitea.rawValue,
                stored: giteaToken != nil,
                prefix: giteaToken.map { String($0.prefix(4)) },
                configured: gitea != nil,
                scope: gitea?.scope,
                instance: gitea?.instance,
                detail: giteaDetail(token: giteaToken, config: gitea)
            ))

        // Every configured forge needs its token, and at least one forge must
        // be configured (GitHub and Gitea are each optional on their own).
        let githubOK = githubConfigured && githubToken != nil
        let giteaOK = gitea != nil && giteaToken != nil
        let allGood =
            (githubOK || giteaOK)
            && (!githubConfigured || githubToken != nil)
            && (gitea == nil || giteaToken != nil)
        return AuthStatusReport(forges: forges, allGood: allGood)
    }

    private static func githubDetail(token: String?, scope: String?) -> String {
        let masked = token.map { "\(String($0.prefix(4)))…" } ?? "—"
        switch (token != nil, scope?.isEmpty == false) {
        case (true, true):
            return "stored in Keychain (\(masked)) · scope: \(scope!)"
        case (true, false):
            return "stored in Keychain (\(masked)) — set repo in config.yaml to use it"
        case (false, true):
            return "no token stored — run: kinhin auth set"
        case (false, false):
            return "no token stored — set repo in config.yaml, then run: kinhin auth set"
        }
    }

    private static func giteaDetail(token: String?, config: KinhinConfig.GiteaForgeConfig?) -> String {
        let masked = token.map { "\(String($0.prefix(4)))…" } ?? "—"
        switch (token != nil, config != nil) {
        case (true, true):
            return "stored in Keychain (\(masked)) · scope: \(config!.scope) @ \(config!.instance)"
        case (true, false):
            return "stored in Keychain (\(masked)) — no gitea: section in config.yaml, not in use"
        case (false, true):
            return "no token stored — run: kinhin auth set --gitea"
        case (false, false):
            return "no token stored — add a gitea: section to config.yaml to use this forge"
        }
    }
}
