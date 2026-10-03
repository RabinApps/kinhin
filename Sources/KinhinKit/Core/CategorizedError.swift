import Foundation

/// An error that classifies itself into one of the `ErrorCategory` kinds.
///
/// The CLI uses `category` to pick the process exit code, so the same error
/// type behaves correctly when thrown from a command or converted to an
/// `ErrorCategory` for reporting.
public protocol CategorizedError: Error {
    var category: ErrorCategory { get }
}

