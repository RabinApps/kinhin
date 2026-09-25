import Foundation

@testable import KinhinKit

/// Configurable `ShellRunning` double shared by every test target. Records each
/// argv, then answers from (in priority order): `throwOnRun`, `failAll`,
/// `failOn`, the next queued `responses` entry, `defaultResult`.
final class FakeShell: ShellRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    /// Queued results, consumed one per call before falling back to `defaultResult`.
    var responses: [ShellResult] = []
    var defaultResult = ShellResult(exitCode: 0, stdout: "", stderr: "")
    /// Every call fails (exit 1) with this stderr.
    var failAll: String?
    /// Calls whose argv contains this element fail (exit 1, stderr "boom").
    var failOn: String?
    /// Every call throws `ShellError.launchFailed`.
    var throwOnRun = false

    /// Every argv passed to `run`, in order.
    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        lock.lock()
        recorded.append(argv)
        let queued = responses.isEmpty ? nil : responses.removeFirst()
        lock.unlock()
        if throwOnRun { throw ShellError.launchFailed("injected") }
        if let failAll { return ShellResult(exitCode: 1, stdout: "", stderr: failAll) }
        if let failOn, argv.contains(failOn) { return ShellResult(exitCode: 1, stdout: "", stderr: "boom") }
        return queued ?? defaultResult
    }
}
