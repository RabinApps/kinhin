import Foundation
import Synchronization

@testable import KinhinKit

/// SSH double that "registers" the runner when its script runs.
final class FakeSSH: SSHExecuting, Sendable {
    private struct State: Sendable {
        var scripts: [String] = []
        var timeouts: [TimeInterval] = []
        /// When set, every exec fails with this text as stderr.
        var failWith: String?
        /// When set (and `failWith` is not), only the exec at this zero-based
        /// call index fails — lets tests fail a later step (e.g. the user
        /// provision script) while earlier steps succeed.
        var failOnCall: Int?
    }

    private let state = Mutex(State())

    var scripts: [String] { state.withLock { $0.scripts } }
    var timeouts: [TimeInterval] { state.withLock { $0.timeouts } }

    /// When set, every exec fails with this text as stderr.
    var failWith: String? {
        get { state.withLock { $0.failWith } }
        set { state.withLock { $0.failWith = newValue } }
    }

    /// When set (and `failWith` is not), only the exec at this zero-based
    /// call index fails — lets tests fail a later step (e.g. the user
    /// provision script) while earlier steps succeed.
    var failOnCall: Int? {
        get { state.withLock { $0.failOnCall } }
        set { state.withLock { $0.failOnCall = newValue } }
    }

    func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws -> ShellResult {
        let failing = state.withLock { state -> String? in
            let callIndex = state.scripts.count
            state.scripts.append(script)
            state.timeouts.append(timeout)
            if let idx = state.failOnCall, idx == callIndex {
                return state.failWith ?? "injected failure"
            }
            return state.failWith
        }
        if let failing {
            return ShellResult(exitCode: 1, stdout: "", stderr: failing)
        }
        return ShellResult(exitCode: 0, stdout: "runner started", stderr: "")
    }
}
