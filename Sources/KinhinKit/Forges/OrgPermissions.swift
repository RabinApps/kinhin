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
                return Report(ok: false, message: "PAT lacks runner-management permission for '\(scope)'.\(remediation(for: scope))")
            case .unauthorized:
                return Report(ok: false, message: "PAT was rejected (401) — expired or revoked. Fix: kinhin auth set")
            case .notFound:
                return Report(ok: false, message: "'\(scope)' not found — check the scope name and that the PAT can access it")
            case .rateLimited(let resetAt):
                return Report(ok: false, message: "GitHub rate limit exhausted; verify later (resets at \(resetAt))")
            default:
                return Report(ok: false, message: "could not verify permission: \((error as LocalizedError).errorDescription ?? "\(error)")")
            }
        } catch {
            return Report(ok: false, message: "could not verify permission: \(error.localizedDescription)")
        }
    }

    private static func remediation(for scope: String) -> String {
        if scope.contains("/") {
            return " grant the classic PAT 'repo' scope, or give a fine-grained token 'Administration: write' on the repository (github.com/settings/tokens)"
        }
        return " for an org scope the PAT needs 'admin:org' (classic) or 'Organization administration: write' (fine-grained) — create/update it at github.com/settings/tokens"
    }
}
