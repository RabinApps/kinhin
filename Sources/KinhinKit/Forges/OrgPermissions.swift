import Foundation

/// Verifies the stored PAT can actually manage runners for the configured
/// scope *before* a fleet starts. The probe mints a runner registration
/// token — the exact API call the fleet's lifecycle depends on — and throws
/// the token away without registering anything: free, idempotent, and it
/// exercises precisely the permission that matters (fine-grained tokens and
/// classic PATs fail here with distinct, actionable errors).
public enum OrgPermissionProbe {
    public struct Report: Equatable, Sendable {
        public let ok: Bool
        public let message: String
        public init(ok: Bool, message: String) {
            self.ok = ok
            self.message = message
        }
    }

    /// Checks runner-management permission for the scope. Works for both
    /// repo scopes ("RabinApps/name") and org scopes — org scopes just get a
    /// more specific remediation hint, since they need org-level rights.
    public static func verify(github: GitHubServing, scope: String) async -> Report {
        do {
            _ = try await github.fetchRegistrationToken()
            let kind = scope.contains("/") ? "repository" : "organization"
            return Report(ok: true, message: "PAT can manage runners for \(kind) '\(scope)' ✓")
        } catch let error as GitHubError {
            switch error {
            case .forbidden:
                return Report(
                    ok: false,
                    message: "PAT lacks runner-management permission for '\(scope)'.\(remediation(for: scope))")
            case .unauthorized:
                return Report(ok: false, message: "PAT was rejected (401) — expired or revoked. Fix: kinhin auth set")
            case .notFound(let what):
                // Distinguish the two 404 failures:
                // - '/runners/registration-token' (mint) -> the PAT can't manage
                //   runners for this scope.
                // - '/runs' or '/jobs' (list/read) -> the PAT can't read the
                //   scope's Actions data.
                let isRunnerManagementEndpoint = what.contains("runners/registration-token")
                if scope.contains("/") {
                    // Repo scope: the token is probably scoped to one repo but
                    // the config uses an org, or it can't reach that repo.
                    return Report(
                        ok: false,
                        message:
                            "PAT can't reach '\(scope)' — check the repo name and that the token has access to it (github.com/settings/tokens)"
                    )
                }
                // Org scope.
                if isRunnerManagementEndpoint {
                    return Report(
                        ok: false,
                        message: "PAT lacks runner-management permission for '\(scope)'.\(remediation(for: scope))")
                }
                // Org scope + 404 on runs/jobs: the PAT was probably minted for
                // one repo (owner/name) but the config serves an org, so the
                // engine can't list queued/running runs across the org's repos.
                // Either switch the config to that repo, or give the token the
                // org-wide Actions read permission.
                return Report(
                    ok: false,
                    message:
                        "PAT can't see the org's queued/running jobs ('\(scope)'). 404 on \(what) — the token needs the repo scope 'RabinApps/name' in config.yaml, or a fine-grained token with 'Actions: Read and write' on the organization. You can change the scope in Advanced → Accounts."
                )
                // report unreachable
                return Report(
                    ok: false,
                    message:
                        "PAT can't read '\(scope)' — check the scope name and that the token can access it (github.com/settings/tokens)"
                )
            case .rateLimited(let resetAt):
                return Report(ok: false, message: "GitHub rate limit exhausted; verify later (resets at \(resetAt))")
            default:
                return Report(
                    ok: false,
                    message: "could not verify permission: \((error as LocalizedError).errorDescription ?? "\(error)")")
            }
        } catch {
            return Report(ok: false, message: "could not verify permission: \(error.localizedDescription)")
        }
    }

    private static func remediation(for scope: String) -> String {
        if scope.contains("/") {
            return
                " grant the classic PAT 'repo' scope, or give a fine-grained token 'Administration: write' on the repository (github.com/settings/tokens)"
        }
        return
            " for an org scope the PAT needs 'admin:org' (classic) or 'Organization administration: write' (fine-grained) — create/update it at github.com/settings/tokens"
    }
}
