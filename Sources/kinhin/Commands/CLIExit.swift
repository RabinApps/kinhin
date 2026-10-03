import Foundation
import KinhinKit

/// Process exit codes. Scripts can branch on them: 1 for anything
/// unclassified, 2 for a bad command line, then one per problem area.
enum CLIExit: Int32 {
    case general = 1
    case usage = 2
    case config = 3
    case runtime = 4
    case auth = 5
    /// 128+SIGINT: the command was cancelled (Ctrl-C) and cleaned up.
    case cancelled = 130

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
