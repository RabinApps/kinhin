import Foundation

/// Verifies that a provider's stored token actually works against the forge
/// — the same mint-registration-token probe `kinhin auth status` and the
/// engine's startup gate use — so the token settings form can show the result
/// inline instead of waiting for a fleet start to fail. Registers nothing;
/// free and idempotent per call.
///
/// Injectable clients (nil → build the live client from the stored token and
/// the config) keep this hermetic in tests.
public enum TokenHealthCheck {
    public struct Report: Equatable, Sendable {
        public let ok: Bool
        public let message: String

        public init(ok: Bool, message: String) {
            self.ok = ok
            self.message = message
        }
    }

    /// Check the GitHub provider against the account's instance (nil =
    /// github.com; a GHES host or GHEC data-residency host otherwise).
    /// Requires a config scope; without one the probe cannot address any API
    /// and reports "not checkable".
    public static func github(
        token: String, scope: String, instance: String? = nil, allowInsecureHTTP: Bool = false,
        account: String? = nil, client github: GitHubServing? = nil
    ) async -> Report {
        let client =
            github
            ?? GitHubClient(
                credentials: GitHubCredentials(
                    token: token, scope: scope, instance: instance, allowInsecureHTTP: allowInsecureHTTP))
        let report = await OrgPermissionProbe.verify(github: client, scope: scope, account: account)
        return Report(ok: report.ok, message: report.ok ? "Token works — \(report.message)" : report.message)
    }

    /// Check the Gitea provider against its configured instance.
    public static func gitea(
        token: String, scope: String, instance: String, allowInsecureHTTP: Bool = false,
        client gitea: GiteaClient? = nil
    ) async -> Report {
        let client =
            gitea
            ?? GiteaClient(
                credentials: GiteaCredentials(
                    token: token, scope: scope, instance: instance, allowInsecureHTTP: allowInsecureHTTP))
        do {
            _ = try await client.fetchRegistrationToken()
            return Report(ok: true, message: "Token works against \(scope) @ \(instance)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return Report(ok: false, message: "Token check failed: \(message)")
        }
    }

    /// Check a GitLab account: the instance is new enough for the runner
    /// creation API, the token has the scopes kinhin uses, and the scope
    /// resolves to a project or group it can see.
    public static func gitlab(
        token: String, scope: String, instance: String?, allowInsecureHTTP: Bool = false,
        client gitlab: GitLabClient? = nil
    ) async -> Report {
        let client =
            gitlab
            ?? GitLabClient(
                credentials: GitLabCredentials(
                    token: token, scope: scope, instance: instance, allowInsecureHTTP: allowInsecureHTTP))
        do {
            let version = try await client.version()
            if let major = Int(version.prefix { $0.isNumber }), major < 16 {
                throw GitLabError.unsupportedVersion(version)
            }
            let scopes = Set(try await client.tokenScopes())
            if !scopes.contains("api") {
                let missing = ["create_runner", "manage_runner", "read_api"].filter { !scopes.contains($0) }
                if !missing.isEmpty { throw GitLabError.insufficientScopes(missing) }
            }
            let resolved = try await client.resolveScope()
            let kind = resolved.isGroup ? "group" : "project"
            return Report(ok: true, message: "Token works against \(kind) \(scope) @ \(client.credentials.instance)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return Report(ok: false, message: "Token check failed: \(message)")
        }
    }

    /// Check a Buildkite account: the API token has the scopes kinhin uses
    /// and the `org/cluster` scope names a cluster it can see.
    public static func buildkite(
        token: String, scope: String,
        client buildkite: BuildkiteClient? = nil
    ) async -> Report {
        let client = buildkite ?? BuildkiteClient(credentials: BuildkiteCredentials(token: token, scope: scope))
        do {
            try await client.verifyScopes()
            let cluster = try await client.resolveCluster()
            return Report(
                ok: true, message: "Token works against cluster \(cluster.name) of \(client.credentials.organization)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return Report(ok: false, message: "Token check failed: \(message)")
        }
    }

    /// Check an Azure DevOps account: the PAT is accepted by the organization
    /// and can manage the configured agent pool.
    public static func azureDevOps(
        token: String, scope: String, instance: String, allowInsecureHTTP: Bool = false,
        client azure: AzureDevOpsClient? = nil
    ) async -> Report {
        let client =
            azure
            ?? AzureDevOpsClient(
                credentials: AzureDevOpsCredentials(
                    token: token, scope: scope, instance: instance, allowInsecureHTTP: allowInsecureHTTP))
        do {
            let pool = try await client.resolvePool()
            return Report(ok: true, message: "Token works against agent pool \(pool.name) @ \(instance)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return Report(ok: false, message: "Token check failed: \(message)")
        }
    }

    /// Check a Bitbucket account: the token is accepted, and the scope's
    /// workspace (and repository, when set) exist and can see runners.
    public static func bitbucket(
        token: String, scope: String,
        client bitbucket: BitbucketClient? = nil
    ) async -> Report {
        let client = bitbucket ?? BitbucketClient(credentials: BitbucketCredentials(token: token, scope: scope))
        do {
            try await client.verifyScope()
            let runners = try await client.listRunners(scope: BitbucketScope(credentials: client.credentials))
            return Report(
                ok: true,
                message: "Token works against \(BitbucketScope(credentials: client.credentials).description) "
                    + "(\(runners.count) runner(s))")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return Report(ok: false, message: "Token check failed: \(message)")
        }
    }

    /// Forge-dispatching convenience for the settings form: finds the account
    /// (`name`, or the forge's primary one), reads *that account's* token via
    /// `keychainToken(forge, accountName)` and probes it. Returns an
    /// actionable "not checkable" report when a prerequisite is missing (no
    /// token stored, or no config account to check against).
    public static func check(
        forge: ForgeID,
        account name: String? = nil,
        config: KinhinConfig?,
        keychainToken: @escaping (ForgeID, String) throws -> String?,
        github: GitHubServing? = nil,
        gitea: GiteaClient? = nil,
        gitlab: GitLabClient? = nil
    ) async -> Report {
        switch resolve(forge: forge, account: name, config: config, keychainToken: keychainToken) {
        case .notCheckable(let report):
            return report
        case .ready(let account, let token):
            return await probe(account, token: token, github: github, gitea: gitea, gitlab: gitlab)
        }
    }

    /// What `check` found for a forge/account pair.
    enum Resolution {
        case ready(AccountConfig, token: String)
        case notCheckable(Report)
    }

    /// Picks the account to check and reads *its* token: the account is keyed
    /// by name (a forge can have several), never by forge alone, so a second
    /// GitLab account is checked with its own token and scope, not the first's.
    static func resolve(
        forge: ForgeID, account name: String?, config: KinhinConfig?,
        keychainToken: (ForgeID, String) throws -> String?
    ) -> Resolution {
        let account = config?.accounts.account(named: name, forge: forge)
        if account == nil, let name, config != nil {
            return .notCheckable(
                Report(ok: false, message: "No \(forge.displayName) account '\(name)' in config.yaml."))
        }
        let tokenName = account?.name ?? name ?? KeychainTokenStore.legacyAccountName(for: forge)
        let stored: String?
        do {
            stored = try keychainToken(forge, tokenName)
        } catch {
            return .notCheckable(Report(ok: false, message: "Token check failed: \(error.localizedDescription)"))
        }
        guard let token = stored else {
            return .notCheckable(
                Report(
                    ok: false,
                    message:
                        "No token stored yet — save one first (\(AuthFix.command(forge: forge, account: tokenName)))."))
        }
        guard let account else {
            if let name {
                return .notCheckable(
                    Report(ok: false, message: "No \(forge.displayName) account '\(name)' in config.yaml."))
            }
            let missing =
                forge == .github
                ? "No scope to check — add a GitHub account to config.yaml first."
                : "No \(forge == .gitea || forge == .forgejo ? forge.rawValue : forge.displayName) account in "
                    + "config.yaml — add one to check the token."
            return .notCheckable(Report(ok: false, message: missing))
        }
        return .ready(account, token: token)
    }

    /// Check any `accounts:` entry's token the way its forge needs: GitHub's
    /// runner-management permission, a Gitea-family registration mint, or
    /// GitLab's version, scopes and scope.
    public static func account(_ account: AccountConfig, token: String) async -> Report {
        await probe(account, token: token)
    }

    private static func probe(
        _ account: AccountConfig, token: String,
        github githubClient: GitHubServing? = nil, gitea giteaClient: GiteaClient? = nil,
        gitlab gitlabClient: GitLabClient? = nil
    ) async -> Report {
        switch account.forge {
        case .github:
            guard !account.scope.isEmpty else {
                return Report(ok: false, message: "No scope to check — add a GitHub account to config.yaml first.")
            }
            return await github(
                token: token, scope: account.scope, instance: account.instance,
                allowInsecureHTTP: account.allowInsecureHTTP ?? false, account: account.name, client: githubClient)
        case .gitea, .forgejo:
            guard let instance = account.instance, !instance.isEmpty else {
                return Report(ok: false, message: "This account has no server address in config.yaml.")
            }
            return await gitea(
                token: token, scope: account.scope, instance: instance,
                allowInsecureHTTP: account.allowInsecureHTTP ?? false, client: giteaClient)
        case .gitlab:
            return await gitlab(
                token: token, scope: account.scope, instance: account.instance,
                allowInsecureHTTP: account.allowInsecureHTTP ?? false, client: gitlabClient)
        case .buildkite:
            return await buildkite(token: token, scope: account.scope)
        case .azuredevops:
            guard let instance = account.instance, !instance.isEmpty else {
                return Report(ok: false, message: "This account has no organization URL in config.yaml.")
            }
            return await azureDevOps(
                token: token, scope: account.scope, instance: instance,
                allowInsecureHTTP: account.allowInsecureHTTP ?? false)
        case .bitbucket:
            return await bitbucket(token: token, scope: account.scope)
        }
    }

    /// The repositories a token can see on a forge (the Connect form's
    /// picker). `instance` is required for Gitea-family forges; GitLab
    /// defaults to gitlab.com.
    public static func repositories(
        forge: ForgeID, token: String, instance: String?, allowInsecureHTTP: Bool = false
    ) async throws -> [RepoRef] {
        switch forge {
        case .github:
            return try await GitHubClient(
                credentials: GitHubCredentials(
                    token: token, scope: "", instance: instance, allowInsecureHTTP: allowInsecureHTTP)
            ).listRepositories()
        case .gitea, .forgejo:
            return try await GiteaClient(
                credentials: GiteaCredentials(
                    token: token, scope: "", instance: instance ?? "", allowInsecureHTTP: allowInsecureHTTP)
            ).listRepositories()
        case .gitlab:
            return try await GitLabClient(
                credentials: GitLabCredentials(
                    token: token, scope: "", instance: instance, allowInsecureHTTP: allowInsecureHTTP)
            ).listRepositories()
        case .buildkite:
            return try await BuildkiteClient(credentials: BuildkiteCredentials(token: token, scope: "")).listScopes()
        case .azuredevops:
            return try await AzureDevOpsClient(
                credentials: AzureDevOpsCredentials(
                    token: token, scope: "", instance: instance ?? "", allowInsecureHTTP: allowInsecureHTTP)
            ).listPools()
        case .bitbucket:
            return try await BitbucketClient(credentials: BitbucketCredentials(token: token, scope: "")).listScopes()
        }
    }
}
