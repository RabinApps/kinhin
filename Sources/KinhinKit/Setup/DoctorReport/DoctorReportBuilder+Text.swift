import Foundation

// The human rendering of `kinhin doctor`: the report's own `plainText`, then
// the config-specific lines that are not part of the JSON contract (config
// path, base image, cache note, org-scope requirements). Living here means the
// CLI renders one report from one probe pass instead of re-probing config.
extension DoctorReportBuilder {
    /// The full human output (no trailing newline).
    public func buildPlainText() async -> String {
        await plainText(for: await build())
    }

    /// The human output for a report the caller already built, so a caller
    /// that also needs `report.ready` (the CLI's exit code) probes once.
    public func plainText(for report: DoctorReport) async -> String {
        let details = configDetailLines()
        return ([report.plainText] + details).joined(separator: "\n")
    }

    /// The config-specific lines below the report. A missing or unparseable
    /// config simply has no config-specific lines beyond the path; the
    /// report's checks already flag it.
    func configDetailLines() -> [String] {
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
        lines += orgScopeLines(cfg)
        return lines
    }

    /// Org scopes: the permissions the token needs. Whether it actually has
    /// them is `--check-tokens`'s job (the `check NAME` rows), not a hidden network call.
    private func orgScopeLines(_ cfg: KinhinConfig) -> [String] {
        guard let account = cfg.primaryGitHub, !account.scope.isEmpty, !account.scope.contains("/") else { return [] }
        let org = account.scope
        var lines = ["  scope:      organization '\(org)' — runners serve every repo"]
        lines.append(
            TokenRequirements.github(scope: org).plainText
                .split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
        return lines
    }
}
