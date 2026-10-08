import Foundation

/// The one exit-code rule for every command that reports a state (`status`,
/// `stop`, `pause`, `resume`, `setup status`, `auth status`, `doctor`):
///
///   * healthy / done          -> 0
///   * ran, but needs attention -> 1 (no daemon, a failing check, a token not ready)
///
/// Usage errors (2) and config/runtime/auth failures (3-5) are not states;
/// they end through `fail(_:exit:)`. `--quiet` suppresses the output and leaves
/// this code as the whole answer; `--json` prints the document either way.
enum ExitRule {
    /// The code for a state: nil (exit 0) when healthy, `.needsAttention` otherwise.
    static func code(healthy: Bool) -> CLIExit? {
        healthy ? nil : .needsAttention
    }

    /// Ends the process with the rule's code when the state is not healthy;
    /// returns normally (exit 0) when it is.
    static func finish(healthy: Bool) {
        if let code = code(healthy: healthy) { exit(code.rawValue) }
    }
}
