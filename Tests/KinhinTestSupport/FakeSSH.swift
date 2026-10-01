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
        /// stdout returned per exec, by zero-based call index; other calls
        /// answer the default ("runner started"). The image bake's first
        /// exec is the `uname -s` guest probe ("Linux"/"Darwin").
        var stdoutByCall: [Int: String] = [:]
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

    /// Sets the stdout the exec at `call` (zero-based) returns. The image
    /// bake's first exec is the `uname -s` guest-OS probe.
    func setStdout(_ text: String, forCall call: Int) {
        state.withLock { $0.stdoutByCall[call] = text }
    }

    func exec(vm: String, user: String, ip: String, script: String, timeout: TimeInterval) async throws -> ShellResult {
        let callIndex = state.withLock { state -> Int in
            let index = state.scripts.count
            state.scripts.append(script)
            state.timeouts.append(timeout)
            return index
        }
        let failing = state.withLock { state -> String? in
            if let idx = state.failOnCall, idx == callIndex {
                return state.failWith ?? "injected failure"
            }
            return state.failWith
        }
        let stdout = state.withLock { state in
            // The image bake's first exec is the `uname -s` guest probe
            // (GuestOS.probeScript); answer "Darwin" so VM tests keep their
            // macOS-bake shape. (Linux-guest tests override it via
            // setStdout(_:forCall:).)
            if script.trimmingCharacters(in: .whitespacesAndNewlines) == "uname -s" {
                return state.stdoutByCall[callIndex] ?? "Darwin"
            }
            return state.stdoutByCall[callIndex] ?? "runner started"
        }
        if let failing {
            return ShellResult(exitCode: 1, stdout: "", stderr: failing)
        }
        return ShellResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}
