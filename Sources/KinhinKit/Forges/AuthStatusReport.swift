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

    /// One entry per `accounts:` list entry (the additional accounts; the
    /// legacy github/gitea accounts stay in `forges`). Empty without any.
    public struct Account: Codable, Equatable, Sendable {
        public let name: String
        /// "github" | "gitea".
        public let forge: String
        public let stored: Bool
        /// First four characters of the stored token, or null.
        public let prefix: String?
        public let scope: String
        /// Gitea instance URL; null for GitHub.
        public let instance: String?
        public let detail: String

        public init(
            name: String, forge: String, stored: Bool, prefix: String?, scope: String, instance: String?,
            detail: String
        ) {
            self.name = name
            self.forge = forge
            self.stored = stored
            self.prefix = prefix
            self.scope = scope
            self.instance = instance
            self.detail = detail
        }
    }

    /// One entry per forge, in `ForgeID.allCases` order (github first).
    public let forges: [Forge]
    /// The additional named accounts (see `Account`).
    public let accounts: [Account]
    /// True when every forge the fleet actually needs has a stored token:
    /// GitHub must be stored *and* have a scope; Gitea only when configured.
    /// Mirrors the CLI's exit code for `auth status --json`.
    public let allGood: Bool

    public init(forges: [Forge], allGood: Bool, accounts: [Account] = []) {
        self.forges = forges
        self.allGood = allGood
        self.accounts = accounts
    }

    /// `accounts` was added after the first release: older documents omit it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        forges = try container.decode([Forge].self, forKey: .forges)
        allGood = try container.decode(Bool.self, forKey: .allGood)
        accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case forges, accounts, allGood
    }
}

/// Builds AuthStatusReport from injected state. `load` stands in for the
/// Keychain so tests stay hermetic; `.live` passes `KeychainTokenStore.load`.
public enum AuthStatusReporter {
    public static func report(
        config: KinhinConfig?, load: (ForgeID) throws -> String?,
        loadAccount: (ForgeID, String) throws -> String? = { try KeychainTokenStore.load(forge: $0, name: $1) }
    ) -> AuthStatusReport {
        let githubRead = read { try load(.github) }
        let githubToken = githubRead.token
        let repo = config?.repo
        // The starter placeholder repo means "no GitHub" (Gitea-only configs).
        let githubConfigured = !(repo ?? "").isEmpty && repo != ConfigLoader.templateRepo

        let giteaRead = read { try load(.gitea) }
        let giteaToken = giteaRead.token
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
                detail: githubRead.failureDetail ?? githubDetail(token: githubToken, scope: repo)
            ))
        forges.append(
            AuthStatusReport.Forge(
                id: ForgeID.gitea.rawValue,
                stored: giteaToken != nil,
                prefix: giteaToken.map { String($0.prefix(4)) },
                configured: gitea != nil,
                scope: gitea?.scope,
                instance: gitea?.instance,
                detail: giteaRead.failureDetail
                    ?? giteaDetail(token: giteaToken, config: gitea, section: "gitea", fix: "--gitea")
            ))
        let forgejoRead = read { try load(.forgejo) }
        let forgejoToken = forgejoRead.token
        let forgejo = config?.forgejo
        forges.append(
            AuthStatusReport.Forge(
                id: ForgeID.forgejo.rawValue,
                stored: forgejoToken != nil,
                prefix: forgejoToken.map { String($0.prefix(4)) },
                configured: forgejo != nil,
                scope: forgejo?.scope,
                instance: forgejo?.instance,
                detail: forgejoRead.failureDetail
                    ?? giteaDetail(token: forgejoToken, config: forgejo, section: "forgejo", fix: "--forgejo")
            ))

        // Every configured forge needs its token, and at least one forge must
        // be configured (each forge is optional on its own).
        let githubOK = githubConfigured && githubToken != nil
        let giteaOK = gitea != nil && giteaToken != nil
        let forgejoOK = forgejo != nil && forgejoToken != nil
        let accounts = (config?.accounts ?? []).map { account -> AuthStatusReport.Account in
            let accountRead = read { try loadAccount(account.forge, account.name) }
            let token = accountRead.token
            let masked = token.map { "\(String($0.prefix(4)))…" }
            let detail =
                accountRead.failureDetail
                ?? masked.map { "stored in Keychain (\($0)) · scope: \(account.scope)" }
                ?? "no token stored — run: kinhin auth set --account \(account.name)"
            return AuthStatusReport.Account(
                name: account.name, forge: account.forge.rawValue, stored: token != nil,
                prefix: token.map { String($0.prefix(4)) }, scope: account.scope, instance: account.instance,
                detail: detail)
        }
        let accountsOK = accounts.allSatisfy(\.stored)
        let anyForge = githubOK || giteaOK || forgejoOK || accounts.contains(where: \.stored)
        let allGood =
            anyForge
            && (!githubConfigured || githubToken != nil)
            && (gitea == nil || giteaToken != nil)
            && (forgejo == nil || forgejoToken != nil)
            && accountsOK
        return AuthStatusReport(forges: forges, allGood: allGood, accounts: accounts)
    }

    /// One Keychain read. A failure is kept apart from "no token stored" so the
    /// row can say what actually went wrong instead of asking the user to
    /// re-enter a token that is already saved.
    private struct Read {
        let token: String?
        let failure: String?

        var failureDetail: String? { failure.map { "Keychain error — \($0)" } }
    }

    private static func read(_ body: () throws -> String?) -> Read {
        do {
            return Read(token: try body(), failure: nil)
        } catch {
            return Read(token: nil, failure: error.localizedDescription)
        }
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

    private static func giteaDetail(
        token: String?, config: KinhinConfig.GiteaForgeConfig?, section: String, fix: String
    ) -> String {
        let masked = token.map { "\(String($0.prefix(4)))…" } ?? "—"
        switch (token != nil, config != nil) {
        case (true, true):
            return "stored in Keychain (\(masked)) · scope: \(config!.scope) @ \(config!.instance)"
        case (true, false):
            return "stored in Keychain (\(masked)) — no \(section): section in config.yaml, not in use"
        case (false, true):
            return "no token stored — run: kinhin auth set \(fix)"
        case (false, false):
            return "no token stored — add a \(section): section to config.yaml to use this forge"
        }
    }
}
