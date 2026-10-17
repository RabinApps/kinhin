import Synchronization
import XCTest

@testable import KinhinKit

/// The per-tier readiness cache: ready answers last longer than not-ready ones, and cancelled probes are not cached.
final class TierReadinessTests: XCTestCase {
    /// Answers each probe in turn and counts the calls.
    private final class ScriptedProbe: Sendable {
        private let state: Mutex<(calls: Int, answers: [Bool])>

        init(_ answers: [Bool]) {
            state = Mutex((calls: 0, answers: answers))
        }

        var calls: Int { state.withLock { $0.calls } }

        func next() -> Bool {
            state.withLock { state in
                state.calls += 1
                return state.answers.isEmpty ? false : state.answers.removeFirst()
            }
        }
    }

    func testAReadyAnswerIsReusedWithinTheRecheckWindow() async {
        let readiness = TierReadiness()
        let probe = ScriptedProbe([true, false])
        let start = Date()
        let first = await readiness.isReady(now: start, probe: { probe.next() })
        let second = await readiness.isReady(
            now: start.addingTimeInterval(TierReadiness.recheck - 1), probe: { probe.next() })
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(probe.calls, 1)
    }

    func testANotReadyAnswerIsReusedOnlyBriefly() async {
        let readiness = TierReadiness()
        let probe = ScriptedProbe([false, true])
        let start = Date()
        let first = await readiness.isReady(now: start, probe: { probe.next() })
        let soon = await readiness.isReady(
            now: start.addingTimeInterval(TierReadiness.notReadyRecheck - 1), probe: { probe.next() })
        XCTAssertFalse(first)
        XCTAssertFalse(soon)
        XCTAssertEqual(probe.calls, 1)
    }

    func testAModelPulledAfterANotReadyAnswerIsFoundAfterTheShortWindow() async {
        let readiness = TierReadiness()
        let probe = ScriptedProbe([false, true])
        let start = Date()
        _ = await readiness.isReady(now: start, probe: { probe.next() })
        let later = await readiness.isReady(
            now: start.addingTimeInterval(TierReadiness.notReadyRecheck + 1), probe: { probe.next() })
        XCTAssertTrue(later)
        XCTAssertEqual(probe.calls, 2)
    }

    func testACancelledProbeIsNotCached() async {
        let readiness = TierReadiness()
        let probe = ScriptedProbe([true, true])
        let start = Date()
        let task = Task { await readiness.isReady(now: start, probe: { probe.next() }) }
        task.cancel()
        _ = await task.value
        _ = await readiness.isReady(now: start, probe: { probe.next() })
        XCTAssertEqual(probe.calls, 2)
    }
}
