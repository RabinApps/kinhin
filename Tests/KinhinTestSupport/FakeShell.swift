import Foundation
import Synchronization

@testable import KinhinKit

/// Configurable `ShellRunning` double shared by every test target. Records each
/// argv, then answers from (in priority order): `throwOnRun`, `failAll`,
/// `failOn`, the next queued `responses` entry, `defaultResult`.
final class FakeShell: ShellRunning, Sendable {
    private struct State: Sendable {
        var recorded: [[String]] = []
        var responses: [ShellResult] = []
        var defaultResult = ShellResult(exitCode: 0, stdout: "", stderr: "")
        /// Every call fails (exit 1) with this stderr.
        var failAll: String?
        /// Calls whose argv contains this element fail (exit 1, stderr "boom").
        var failOn: String?
        /// Every call throws `ShellError.launchFailed`.
        var throwOnRun = false
    }

    private let state = Mutex(State())

    /// Queued results, consumed one per call before falling back to `defaultResult`.
    var responses: [ShellResult] {
        get { state.withLock { $0.responses } }
        set { state.withLock { $0.responses = newValue } }
    }

    var defaultResult: ShellResult {
        get { state.withLock { $0.defaultResult } }
        set { state.withLock { $0.defaultResult = newValue } }
    }

    /// Every call fails (exit 1) with this stderr.
    var failAll: String? {
        get { state.withLock { $0.failAll } }
        set { state.withLock { $0.failAll = newValue } }
    }

    /// Calls whose argv contains this element fail (exit 1, stderr "boom").
    var failOn: String? {
        get { state.withLock { $0.failOn } }
        set { state.withLock { $0.failOn = newValue } }
    }

    /// Every call throws `ShellError.launchFailed`.
    var throwOnRun: Bool {
        get { state.withLock { $0.throwOnRun } }
        set { state.withLock { $0.throwOnRun = newValue } }
    }

    /// Every argv passed to `run`, in order.
    var calls: [[String]] {
        state.withLock { $0.recorded }
    }

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        let answer = state.withLock { state -> ShellResult? in
            state.recorded.append(argv)
            if state.throwOnRun { return nil }
            if let failAll = state.failAll {
                return ShellResult(exitCode: 1, stdout: "", stderr: failAll)
            }
            if let failOn = state.failOn, argv.contains(failOn) {
                return ShellResult(exitCode: 1, stdout: "", stderr: "boom")
            }
            return state.responses.isEmpty ? nil : state.responses.removeFirst()
        }
        if throwOnRun { throw ShellError.launchFailed("injected") }
        return answer ?? state.withLock { $0.defaultResult }
        // Note: `defaultResult` is read after the lock is released by design;
        // a test setting knobs between calls cannot observe the difference.
    }
}
