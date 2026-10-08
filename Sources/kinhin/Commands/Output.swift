import Foundation
import KinhinKit

/// Writes to stderr, keeping stdout clean for machine-readable output.
func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// A non-fatal problem. Goes to stderr so `--json` output stays parseable.
func warn(_ message: String) {
    printError("warning: \(message)")
}

/// Ends the process with `code`. Under `--json` the failure is the
/// `ErrorDocument` on stdout; otherwise `kinhin: <message>` on stderr.
func fail(_ message: String, exit code: CLIExit = .general) -> Never {
    ErrorReporter.report(message, code: code)
    exit(code.rawValue)
}

/// Ends the process for a thrown error, with an exit code matching its kind.
func fail(_ error: Error) -> Never {
    fail(error.localizedDescription, exit: CLIExit(error))
}
