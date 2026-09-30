import Foundation
import Synchronization

@testable import KinhinKit

/// A scripted answer: what to match against the argv, and what to reply.
/// Needles match as *substrings* of any single argv element — a probe that
/// runs `/bin/bash -c "<one long command string>"` puts whole command lines
/// into one element, so element equality would never match them.
struct ScriptedResponse: Sendable {
    /// When non-nil, the call fails with `ShellError.launchFailed(reason)`.
    var throwReason: String?
    var result: ShellResult?

    /// Match this entry when any argv element contains `contains`...
    init(whenContains contains: String, _ result: ShellResult) {
        self.contains = contains
        self.result = result
    }

    /// ...or when every needle of `allOf` appears (each within any element).
    init(whenContainsAll allOf: [String], _ result: ShellResult) {
        self.allOf = allOf
        self.result = result
    }

    /// Match (and throw) whenever any argv element contains `contains`.
    init(whenContainsThrowing contains: String, reason: String) {
        self.contains = contains
        self.throwReason = reason
    }

    var contains: String?
    var allOf: [String] = []

    func matches(_ argv: [String]) -> Bool {
        func has(_ needle: String) -> Bool { argv.contains { $0.contains(needle) } }
        if let contains, !has(contains) { return false }
        for needle in allOf where !has(needle) { return false }
        return contains != nil || !allOf.isEmpty
    }
}

/// Configurable `ShellRunning` double shared by every test target. Records each
/// argv, then answers from (in priority order): `throwOnRun`, `failAll`,
/// `failOn`, the next queued `responses` entry, `scriptedResponses`,
/// `defaultResult`.
final class FakeShell: ShellRunning, Sendable {
    private enum Answer: Sendable {
        case result(ShellResult)
        case launchFailed(String)
    }

    private struct State: Sendable {
        var recorded: [[String]] = []
        var responses: [ShellResult] = []
        var scriptedResponses: [ScriptedResponse] = []
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

    /// Argv-matched answers, consulted for every call in order. Takes
    /// priority over `defaultResult` (but after the queue and fail hooks).
    /// Lets a test key answers to specific commands — `tart --version`,
    /// `log show`, a probe script — without a private double.
    var scriptedResponses: [ScriptedResponse] {
        get { state.withLock { $0.scriptedResponses } }
        set { state.withLock { $0.scriptedResponses = newValue } }
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
        let answer = state.withLock { state -> Answer? in
            state.recorded.append(argv)
            if state.throwOnRun { return .launchFailed("injected") }
            if let failAll = state.failAll {
                return .result(ShellResult(exitCode: 1, stdout: "", stderr: failAll))
            }
            if let failOn = state.failOn, argv.contains(failOn) {
                return .result(ShellResult(exitCode: 1, stdout: "", stderr: "boom"))
            }
            if !state.responses.isEmpty {
                return .result(state.responses.removeFirst())
            }
            for scripted in state.scriptedResponses where scripted.matches(argv) {
                if let reason = scripted.throwReason { return .launchFailed(reason) }
                return .result(scripted.result ?? state.defaultResult)
            }
            return nil
        }
        switch answer {
        case .launchFailed(let reason): throw ShellError.launchFailed(reason)
        case .result(let result): return result
        case nil: return state.withLock { $0.defaultResult }
        }
        // Note: the `nil` fallback reads `defaultResult` after the lock is
        // released by design; a test setting knobs between calls cannot
        // observe the difference.
    }
}
