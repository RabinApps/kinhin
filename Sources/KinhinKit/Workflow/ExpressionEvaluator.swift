import Foundation

/// The small subset of GitHub Actions expressions the local runner evaluates:
/// `${{ … }}` substitution inside `run:` scripts and the handful of `if:`
/// conditions it understands. Anything else is reported, never guessed.
struct ExpressionEvaluator: Sendable {
    /// The repository directory (`github.workspace`).
    let root: URL

    /// What an `if:` condition means for one step.
    struct Condition: Equatable {
        /// False when the step must not run.
        let shouldRun: Bool
        /// True for `always()` / `failure()`: run even after an earlier failure.
        let forceRun: Bool
        let notice: String?
        /// True when the condition is outside the supported subset, so the
        /// step was skipped without being evaluated (not a deliberate skip).
        var unsupported = false
    }

    /// Expands the supported expressions in `script`: `github.workspace`,
    /// `runner.os`, `runner.arch`, `env.NAME` and `secrets.NAME` (secrets are
    /// unavailable locally and expand to an empty string with a notice).
    /// Any `${{` left over is reported as an unknown expression.
    func expand(_ script: String, env: [String: String], notices: inout [String]) -> String {
        var result = script
        let replacements = [
            "${{ github.workspace }}": root.path, "${{ runner.os }}": "macOS", "${{ runner.arch }}": "arm64",
        ]
        for (expression, value) in replacements { result = result.replacingOccurrences(of: expression, with: value) }
        let pattern = #"\$\{\{\s*(env|secrets)\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}"#
        // A constant pattern; if it ever failed, expressions would stay unexpanded, not crash.
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard match.numberOfRanges == 3 else { continue }
                let kind = ns.substring(with: match.range(at: 1))
                let key = ns.substring(with: match.range(at: 2))
                let replacement: String
                if kind == "env" {
                    replacement = env[key] ?? ""
                } else {
                    replacement = ""
                    if !notices.contains("secrets are unavailable locally; \(key) expanded to an empty string") {
                        notices.append("secrets are unavailable locally; \(key) expanded to an empty string")
                    }
                }
                if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: replacement) }
            }
        }
        if result.contains("${{") { notices.append("unknown expression left literal") }
        return result
    }

    /// Evaluates a step's `if:` (nil = always run). Supports `true`, `false`,
    /// `success()`, `failure()`, `always()` and `cancelled()`, bare or wrapped
    /// in `${{ }}`.
    func evaluate(condition raw: String?, previousFailure: Bool) -> Condition {
        guard let raw else { return Condition(shouldRun: true, forceRun: false, notice: nil) }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "${{", with: "")
            .replacingOccurrences(of: "}}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "true": return Condition(shouldRun: true, forceRun: false, notice: nil)
        case "success()":
            return Condition(
                shouldRun: !previousFailure, forceRun: false,
                notice: previousFailure ? "condition success() evaluated false" : nil)
        case "false": return Condition(shouldRun: false, forceRun: false, notice: "condition false evaluated; skipped")
        case "always()": return Condition(shouldRun: true, forceRun: true, notice: nil)
        case "failure()": return Condition(shouldRun: previousFailure, forceRun: true, notice: nil)
        case "cancelled()": return Condition(shouldRun: false, forceRun: false, notice: nil)
        default:
            return Condition(
                shouldRun: false, forceRun: false, notice: "unsupported condition '\(raw)' skipped", unsupported: true)
        }
    }
}
