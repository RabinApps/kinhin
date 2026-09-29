import Foundation
import Synchronization

@testable import KinhinKit

/// Configurable `ShellRunning` double shared by every test target. Records each
/// argv, then answers from (in priority order): `throwOnRun`, `failAll`,
/// `failOn`, the next queued `responses` entry, `defaultResult`.
final class FakeShell: ShellRunning, @unchecked Sendable {
    private struct State: Sendable {
        var recorded: [[String]] = []
        var responses: [ShellResult] = []
    }

    private let state = Mutex(State())

    /// Queued results, consumed one per call before falling back to `defaultResult`.
    var responses: [ShellResult] {
        get { state.withLock { $0.responses } }
        set { state.withLock { $0.responses = newValue } }
    }

    var defaultResult = ShellResult(exitCode: 0, stdout: "", stderr: "")
    /// Every call fails (exit 1) with this stderr.
    var failAll: String?
    /// Calls whose argv contains this element fail (exit 1, stderr "boom").
    var failOn: String?
    /// Every call throws `ShellError.launchFailed`.
    var throwOnRun = false

    /// Every argv passed to `run`, in order.
    var calls: [[String]] {
        state.withLock { $0.recorded }
    }

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        let queued = state.withLock { state -> ShellResult? in
            state.recorded.append(argv)
            return state.responses.isEmpty ? nil : state.responses.removeFirst()
        }
        if throwOnRun { throw ShellError.launchFailed("injected") }
        if let failAll { return ShellResult(exitCode: 1, stdout: "", stderr: failAll) }
        if let failOn, argv.contains(failOn) { return ShellResult(exitCode: 1, stdout: "", stderr: "boom") }
        return queued ?? defaultResult
    }
}
