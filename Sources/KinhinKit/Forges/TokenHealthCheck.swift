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

    /// Check the GitHub provider. Requires a config scope; without one the
    /// probe cannot address any API and reports "not checkable".
    public static func github(
        token: String, scope: String,
        client github: GitHubServing? = nil
    ) async -> Report {
        let client = github ?? GitHubClient(credentials: GitHubCredentials(token: token, scope: scope))
        let report = await OrgPermissionProbe.verify(github: client, scope: scope)
        return Report(ok: report.ok, message: report.ok ? "Token works — \(report.message)" : report.message)
    }

    /// Check the Gitea provider against its configured instance.
    public static func gitea(
        token: String, config: KinhinConfig.GiteaForgeConfig,
        client gitea: GiteaClient? = nil
    ) async -> Report {
        let client =
            gitea
            ?? GiteaClient(credentials: GiteaCredentials(token: token, scope: config.scope, instance: config.instance))
        do {
            _ = try await client.fetchRegistrationToken()
            return Report(ok: true, message: "Token works against \(config.scope) @ \(config.instance)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return Report(ok: false, message: "Token check failed: \(message)")
        }
    }

    /// Check a GitLab account: the instance is new enough for the runner
    /// creation API, the token has the scopes kinhin uses, and the scope
    /// resolves to a project or group it can see.
    public static func gitlab(
        token: String, scope: String, instance: String?,
        client gitlab: GitLabClient? = nil
    ) async -> Report {
        let client =
            gitlab ?? GitLabClient(credentials: GitLabCredentials(token: token, scope: scope, instance: instance))
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

    /// Forge-dispatching convenience for the settings form: resolves the
    /// stored token (via `keychainToken`) and the config scope, and returns
    /// an actionable "not checkable" report when a prerequisite is missing
    /// (no token stored, or no config scope/section to check against).
    public static func check(
        forge: ForgeID,
        config: KinhinConfig?,
        keychainToken: @escaping (ForgeID) throws -> String?,
        github: GitHubServing? = nil,
        gitea: GiteaClient? = nil
    ) async -> Report {
        let stored: String?
        do {
            stored = try keychainToken(forge)
        } catch {
            return Report(ok: false, message: "Token check failed: \(error.localizedDescription)")
        }
        guard let token = stored else {
            return Report(ok: false, message: "No token stored yet — save one first.")
        }
        switch forge {
        case .github:
            guard let scope = config?.repo, !scope.isEmpty else {
                return Report(ok: false, message: "No scope to check — set repo in config.yaml first.")
            }
            return await Self.github(token: token, scope: scope, client: github)
        case .gitea:
            guard let giteaConfig = config?.gitea else {
                return Report(ok: false, message: "No gitea: section in config.yaml — add one to check the token.")
            }
            return await Self.gitea(token: token, config: giteaConfig, client: gitea)
        case .forgejo:
            guard let forgejoConfig = config?.forgejo else {
                return Report(ok: false, message: "No forgejo: section in config.yaml — add one to check the token.")
            }
            return await Self.gitea(token: token, config: forgejoConfig, client: gitea)
        case .gitlab:
            // GitLab lives in accounts:; the form checks the one named "gitlab".
            guard let account = config?.accounts.first(where: { $0.forge == .gitlab }) else {
                return Report(ok: false, message: "No GitLab account in config.yaml — add one to check the token.")
            }
            return await Self.gitlab(token: token, scope: account.scope, instance: account.instance)
        }
    }
}
