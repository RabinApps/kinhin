import Foundation

// The human rendering of `kinhin doctor`: the report's own `plainText`, then
// the config-specific lines that are not part of the JSON contract (config
// path, base image, cache note, org-scope permissions). Living here means the
// CLI renders one report from one probe pass instead of re-probing config.
extension DoctorReportBuilder {
    /// The full human output (no trailing newline).
    public func buildPlainText() async -> String {
        let report = await build()
        let details = await configDetailLines()
        return ([report.plainText] + details).joined(separator: "\n")
    }

    /// The config-specific lines below the report. A missing or unparseable
    /// config simply has no config-specific lines beyond the path; the
    /// report's checks already flag it.
    func configDetailLines() async -> [String] {
        let exists: Bool
        let cfg: KinhinConfig?
        switch config {
        case .live:
            exists = FileManager.default.fileExists(atPath: Paths.config.path)
            // An unparseable file is flagged by the report's checks; here it
            // just has no config-specific lines.
            cfg = try? ConfigLoader.load()
        case .missing:
            exists = false
            cfg = nil
        case .invalid, .template:
            exists = true
            cfg = nil
        case .loaded(let loaded):
            exists = true
            cfg = loaded
        }
        var lines = ["  config:     \(exists ? Paths.config.path : "missing — run: kinhin config init")"]
        guard let cfg else { return lines }
        lines.append("  image:      \(cfg.image)")
        if !cfg.projects.isEmpty, !cfg.sharesToolchainCache {
            lines.append(
                "  cache note: no project sets share_cache — per-job `kinhin-toolchain install` steps download from scratch every job"
            )
        }
        lines += await orgPermissionLines(cfg)
        return lines
    }

    /// Org scopes: what the token needs, then an active check — mint (and
    /// discard) a registration token, the exact call the fleet depends on.
    private func orgPermissionLines(_ cfg: KinhinConfig) async -> [String] {
        guard let account = cfg.primaryGitHub, !account.scope.isEmpty, !account.scope.contains("/") else { return [] }
        let org = account.scope
        var lines = ["  scope:      organization '\(org)' — runners serve every repo"]
        lines.append(
            TokenRequirements.github(scope: org).plainText
                .split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
        do {
            if let token = try accountLoad(.github, account.name) {
                lines.append("  org perms:  \(await orgPermissionCheck(token, org))")
            } else {
                lines.append(
                    "  org perms:  cannot verify — no token stored (run: kinhin auth set --account \(account.name))")
            }
        } catch {
            lines.append("  org perms:  cannot verify — \(error.localizedDescription)")
        }
        return lines
    }
}
