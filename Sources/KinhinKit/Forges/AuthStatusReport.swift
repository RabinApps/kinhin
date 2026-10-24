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
        /// Instance URL for self-hosted forges (GitHub enterprise, Gitea);
        /// null when the forge runs on its default host (github.com).
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
        /// Instance URL for self-hosted forges (GitHub enterprise, Gitea);
        /// null when the forge runs on its default host (github.com).
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

    /// One entry per classic forge: github, gitea, forgejo (a fixed JSON
    /// contract; other forges appear only under `accounts`).
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

    /// The report for one account only: its `accounts` entry, or the classic
    /// forge row an account named like the forge (`github`, `gitea`,
    /// `forgejo`) drives. `allGood` then reflects just that account.
    public func narrowed(toAccount name: String) -> AuthStatusReport {
        let forges = forges.filter { $0.id == name }
        let accounts = accounts.filter { $0.name == name }
        // The same verdict as the full report: an account needs its token and a usable scope.
        let good = !accounts.isEmpty && accounts.allSatisfy { $0.stored && !$0.scope.isEmpty }
        return AuthStatusReport(forges: forges, allGood: good, accounts: accounts)
    }
}

/// Builds AuthStatusReport from injected state. `load` stands in for the
/// Keychain so tests stay hermetic; `.live` passes `KeychainTokenStore.load`.
public enum AuthStatusReporter {
    public static func report(
        config: KinhinConfig?, load: (ForgeID) throws -> String?,
        loadAccount: (ForgeID, String) throws -> String? = { try KeychainTokenStore.load(forge: $0, name: $1) }
    ) -> AuthStatusReport {
        let accounts = config?.accounts ?? []
        var forges: [AuthStatusReport.Forge] = []
        // The three classic forge rows keep their JSON contract (GitLab has
        // no standalone row — its accounts appear in the list below).
        for forge in [ForgeID.github, .gitea, .forgejo] {
            // The conventional account (named like the forge) drives the
            // per-forge row; additional accounts of the same forge show under
            // `accounts` below. The row is a view of that account, so it reads
            // the account's own token (keyed by name, not by forge). Only with
            // no account configured does it fall back to the forge-keyed item,
            // to report a token stored ahead of its config entry.
            let account = accounts.primary(for: forge)
            let forgeRead = read {
                if let account { return try loadAccount(account.forge, account.name) }
                return try load(forge)
            }
            let token = forgeRead.token
            let masked = token.map { String($0.prefix(4)) }
            forges.append(
                AuthStatusReport.Forge(
                    id: forge.rawValue,
                    stored: token != nil,
                    prefix: masked,
                    configured: account != nil,
                    scope: account?.scope,
                    instance: account?.instance,
                    detail: forgeRead.failureDetail
                        ?? accountDetail(token: token, account: account, forge: forge)
                ))
        }

        // Every configured account needs its token and a usable scope, and
        // at least one account must be configured (each forge is optional on
        // its own). A stored token with an empty scope cannot route a single
        // job, so it must not satisfy the report.
        let accountRows = accounts.map { account -> AuthStatusReport.Account in
            let accountRead = read { try loadAccount(account.forge, account.name) }
            let token = accountRead.token
            let masked = token.map { "\(String($0.prefix(4)))…" }
            let detail =
                accountRead.failureDetail
                ?? masked.map { "stored in Keychain (\($0)) · scope: \(account.scope)" }
                ?? "no token stored — run: \(AuthFix.command(forge: account.forge, account: account.name))"
            return AuthStatusReport.Account(
                name: account.name, forge: account.forge.rawValue, stored: token != nil,
                prefix: token.map { String($0.prefix(4)) }, scope: account.scope, instance: account.instance,
                detail: detail)
        }
        let allGood = !accountRows.isEmpty && accountRows.allSatisfy { $0.stored && !$0.scope.isEmpty }
        return AuthStatusReport(forges: forges, allGood: allGood, accounts: accountRows)
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

    /// Detail for one forge row: the account (when configured) pairs with the
    /// token to explain what is missing. Self-hosted instances appear in the
    /// scope line (`scope: org @ https://…`) like the old gitea: rows did.
    private static func accountDetail(token: String?, account: AccountConfig?, forge: ForgeID) -> String {
        let masked = token.map { "\(String($0.prefix(4)))…" } ?? "—"
        let name = forge.rawValue
        let fix = AuthFix.command(forge: forge, account: account?.name)
        let scopeLine: (AccountConfig) -> String = { account in
            var line = "scope: \(account.scope)"
            if let instance = account.instance, !instance.isEmpty { line += " @ \(instance)" }
            return line
        }
        switch (token, account) {
        case (.some, .some(let account)):
            return "stored in Keychain (\(masked)) · \(scopeLine(account))"
        case (.some, .none):
            return "stored in Keychain (\(masked)) — add a \(name) account to config.yaml to use it"
        case (.none, .some):
            return "no token stored — run: \(fix)"
        case (.none, .none):
            return "no token stored — add a \(name) account to config.yaml, then run: \(fix)"
        }
    }
}

extension Collection where Element == AccountConfig {
    /// The account that stands for `forge` in single-account views: the one
    /// named like the forge (the legacy name), else the first of that forge.
    func primary(for forge: ForgeID) -> AccountConfig? {
        first { $0.name == forge.rawValue && $0.forge == forge } ?? first { $0.forge == forge }
    }

    /// The account called `name` on `forge`, or the forge's primary account
    /// when no name is given.
    func account(named name: String?, forge: ForgeID) -> AccountConfig? {
        guard let name else { return primary(for: forge) }
        return first { $0.name == name && $0.forge == forge }
    }
}
