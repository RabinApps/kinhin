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
    /// repo scopes ("owner/name") and org scopes — org scopes just get a
    /// more specific remediation hint, since they need org-level rights.
    ///
    /// Two gates: the registration-token mint (runner management) and a
    /// queued/running-jobs read — the exact call the engine polls.
    public static func verify(github: GitHubServing, scope: String) async -> Report {
        do {
            _ = try await github.fetchRegistrationToken()
            let kind = scope.contains("/") ? "repository" : "organization"
            let managed = "PAT can manage runners for \(kind) '\(scope)'"
            do {
                _ = try await github.runningJobs(matching: [])
                return Report(ok: true, message: "\(managed) ✓")
            } catch GitHubError.notFound(let what) {
                return Report(
                    ok: false,
                    message:
                        "\(managed), but the token cannot see queued/running jobs (404 on \(what)).\n"
                        + TokenRequirements.github(scope: scope).plainText)
            } catch {
                let description = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                return Report(
                    ok: false, message: "\(managed), but queue visibility could not be verified: \(description)")
            }
        } catch let error as GitHubError {
            switch error {
            case .forbidden:
                return Report(
                    ok: false,
                    message: "PAT lacks runner-management permission for '\(scope)'.\(remediation(for: scope))")
            case .unauthorized:
                return Report(ok: false, message: "PAT was rejected (401) — expired or revoked. Fix: kinhin auth set")
            case .notFound:
                // Reached only when the registration-token mint itself 404s
                // (queue-read 404s are handled above): the PAT can't manage
                // runners for this scope, or can't reach it at all.
                if scope.contains("/") {
                    // Repo scope: the token is probably scoped to one repo but
                    // the config uses an org, or it can't reach that repo.
                    return Report(
                        ok: false,
                        message:
                            "PAT can't reach '\(scope)' — check the repo name and that the token has access to it (github.com/settings/tokens)"
                    )
                }
                return Report(
                    ok: false,
                    message: "PAT lacks runner-management permission for '\(scope)'.\(remediation(for: scope))")
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
        "\n" + TokenRequirements.github(scope: scope).plainText
    }
}
