import Foundation
import Synchronization

@testable import KinhinKit
@testable import kinhin_app

/// An `UpdateChecking` with scripted answers and no network. `gated` holds
/// `check()` open until `releaseGate()` so tests can observe the in-flight state.
final class FakeUpdateChecker: UpdateChecking {
    private struct State {
        var checkResult: Result<UpdateCheckResult, Error> = .success(.upToDate)
        var downloadResult: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/kinhin-test.dmg"))
        var checks = 0
        var downloads: [String] = []
        var gated = false
        var gate: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    var checkResult: Result<UpdateCheckResult, Error> {
        get { state.withLock { $0.checkResult } }
        set { state.withLock { $0.checkResult = newValue } }
    }
    var downloadResult: Result<URL, Error> {
        get { state.withLock { $0.downloadResult } }
        set { state.withLock { $0.downloadResult = newValue } }
    }
    var gated: Bool {
        get { state.withLock { $0.gated } }
        set { state.withLock { $0.gated = newValue } }
    }
    var checks: Int { state.withLock { $0.checks } }
    var downloads: [String] { state.withLock { $0.downloads } }

    func releaseGate() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.gated = false
            defer { state.gate = nil }
            return state.gate
        }
        continuation?.resume()
    }

    func check() async throws -> UpdateCheckResult {
        state.withLock { $0.checks += 1 }
        if state.withLock({ $0.gated }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    guard state.gated else { return true }
                    state.gate = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return try state.withLock { $0.checkResult }.get()
    }

    func downloadDMG(_ info: UpdateInfo, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        state.withLock { $0.downloads.append(info.tag) }
        return try state.withLock { $0.downloadResult }.get()
    }
}
