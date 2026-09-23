import Foundation

/// Verifies that a provider's stored token actually works against the forge
/// — the same mint-registration-token probe `orchard auth status` and the
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
    public static func github(token: String, scope: String,
                              client github: GitHubServing? = nil) async -> Report {
        let client = github ?? GitHubClient(credentials: GitHubCredentials(token: token, scope: scope))
        let report = await OrgPermissionProbe.verify(github: client, scope: scope)
        return Report(ok: report.ok, message: report.ok ? "Token works — \(report.message)" : report.message)
    }

    /// Check the Gitea provider against its configured instance.
    public static func gitea(token: String, config: OrchardConfig.GiteaForgeConfig,
                             client gitea: GiteaClient? = nil) async -> Report {
        let client = gitea ?? GiteaClient(credentials: GiteaCredentials(token: token, scope: config.scope, instance: config.instance))
        do {
            _ = try await client.fetchRegistrationToken()
            return Report(ok: true, message: "Token works against \(config.scope) @ \(config.instance)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return Report(ok: false, message: "Token check failed: \(message)")
        }
    }

    /// Forge-dispatching convenience for the settings form: resolves the
    /// stored token (via `keychainToken`) and the config scope, and returns
    /// an actionable "not checkable" report when a prerequisite is missing
    /// (no token stored, or no config scope/section to check against).
    public static func check(forge: ForgeID,
                             config: OrchardConfig?,
                             keychainToken: @escaping (ForgeID) -> String?,
                             github: GitHubServing? = nil,
                             gitea: GiteaClient? = nil) async -> Report {
        guard let token = keychainToken(forge) else {
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
        }
    }
}
