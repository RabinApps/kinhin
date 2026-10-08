import Foundation
import KinhinKit

/// Process exit codes. Scripts can branch on them. One rule for every command:
///
///   0  healthy / done: the command did what was asked, and what it reports is fine
///   1  needs attention: it ran, but the state is not healthy (no daemon, a failing
///      check, a token not ready) or the failure fits no other area
///   2  usage error: the command line was wrong; nothing was run
///   3, 4, 5  the config, the runtime/engine, or a token was the problem
///
/// `--quiet` (status, stop, pause, resume, setup status, auth status, doctor)
/// prints nothing so the code is the whole answer. Under `--json` a failure is
/// `{"error": …, "code": …}` on stdout.
enum CLIExit: Int32 {
    case general = 1
    case usage = 2
    case config = 3
    case runtime = 4
    case auth = 5
    /// 128+SIGINT: the command was cancelled (Ctrl-C) and cleaned up.
    case cancelled = 130

    /// "It ran, and something needs attention": exit 1, the same code as `general`.
    static var needsAttention: CLIExit { .general }

    /// The exit code for an error thrown anywhere in the engine or CLI.
    init(_ error: Error) {
        if error is CancellationError {
            // A cancelled command unwound through its own cleanup paths; the
            // process is about to exit 130, not report an engine failure.
            self = .cancelled
            return
        }
        if let cliError = error as? CLIError {
            self = cliError.exit
            return
        }
        switch ErrorCategory(error) {
        case .config: self = .config
        case .auth: self = .auth
        case .runtime: self = .runtime
        case .other: self = .general
        }
    }
}

/// A failure the CLI itself detected (bad arguments, missing prerequisite),
/// carrying the exit code it should end the process with.
struct CLIError: LocalizedError {
    let message: String
    let exit: CLIExit

    init(_ message: String, exit: CLIExit = .general) {
        self.message = message
        self.exit = exit
    }

    var errorDescription: String? { message }
}
