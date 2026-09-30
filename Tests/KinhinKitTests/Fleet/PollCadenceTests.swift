import XCTest

@testable import KinhinKit

final class PollCadenceTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func budget(_ remaining: Int, of limit: Int = 5000, resetIn: TimeInterval = 1800) -> ForgeRateLimit {
        ForgeRateLimit(remaining: remaining, limit: limit, resetAt: start.addingTimeInterval(resetIn))
    }

    func testBusyFleetPollsAtTheConfiguredInterval() {
        var cadence = PollCadence()
        let next = cadence.next(base: 20, idle: false, paused: false, budget: nil, now: start)
        XCTAssertEqual(next.seconds, 20)
        XCTAssertNil(next.slowdown)
    }

    /// Multi-stage workflows leave the fleet empty between jobs: a short
    /// idle spell must not slow the next stage.
    func testIdleWithinTheGraceKeepsTheConfiguredInterval() {
        var cadence = PollCadence()
        _ = cadence.next(base: 20, idle: true, paused: false, budget: nil, now: start)
        let next = cadence.next(
            base: 20, idle: true, paused: false, budget: nil, now: start.addingTimeInterval(PollCadence.idleGrace - 1))
        XCTAssertEqual(next.seconds, 20)
        XCTAssertNil(next.slowdown)
    }

    func testSustainedIdleBacksOffThenDemandRestoresTheInterval() {
        var cadence = PollCadence()
        _ = cadence.next(base: 20, idle: true, paused: false, budget: nil, now: start)
        let idle = cadence.next(
            base: 20, idle: true, paused: false, budget: nil, now: start.addingTimeInterval(PollCadence.idleGrace))
        XCTAssertEqual(idle.seconds, PollCadence.idleInterval)
        XCTAssertEqual(idle.slowdown, .idle)

        let busy = cadence.next(
            base: 20, idle: false, paused: false, budget: nil, now: start.addingTimeInterval(PollCadence.idleGrace + 60)
        )
        XCTAssertEqual(busy.seconds, 20)
        XCTAssertNil(cadence.idleSince, "demand resets the idle clock")
    }

    /// Paused surfaces promise "re-checks the queue every poll_interval".
    func testPausedFleetNeverBacksOffForIdleness() {
        var cadence = PollCadence()
        _ = cadence.next(base: 20, idle: true, paused: true, budget: nil, now: start)
        let next = cadence.next(
            base: 20, idle: true, paused: true, budget: nil, now: start.addingTimeInterval(3600))
        XCTAssertEqual(next.seconds, 20)
        XCTAssertNil(next.slowdown)
    }

    func testAnIntervalAlreadyAboveTheIdleCadenceIsKept() {
        var cadence = PollCadence()
        _ = cadence.next(base: 120, idle: true, paused: false, budget: nil, now: start)
        let next = cadence.next(
            base: 120, idle: true, paused: false, budget: nil, now: start.addingTimeInterval(3600))
        XCTAssertEqual(next.seconds, 120)
        XCTAssertNil(next.slowdown)
    }

    func testBudgetStretchesTheInterval() {
        var cadence = PollCadence()
        XCTAssertEqual(cadence.next(base: 20, idle: false, paused: false, budget: budget(4000), now: start).seconds, 20)
        let tight = cadence.next(base: 20, idle: false, paused: false, budget: budget(1000), now: start)
        XCTAssertEqual(tight.seconds, 40)
        XCTAssertEqual(tight.slowdown, .apiBudget)
        XCTAssertEqual(cadence.next(base: 20, idle: false, paused: false, budget: budget(400), now: start).seconds, 80)
    }

    func testExhaustedBudgetWaitsForTheResetWithinABound() {
        var cadence = PollCadence()
        let soon = cadence.next(base: 20, idle: false, paused: false, budget: budget(0, resetIn: 300), now: start)
        XCTAssertEqual(soon.seconds, 300)
        XCTAssertEqual(soon.slowdown, .apiBudget)
        let far = cadence.next(base: 20, idle: false, paused: false, budget: budget(0, resetIn: 3000), now: start)
        XCTAssertEqual(far.seconds, PollCadence.maxBudgetWait)
        let past = cadence.next(base: 20, idle: false, paused: false, budget: budget(0, resetIn: -10), now: start)
        XCTAssertEqual(past.seconds, 20, "a reset already due waits no longer than usual")
    }

    /// Paused fleets still honor the budget: polling into an exhausted
    /// limit would only fail.
    func testBudgetAppliesWhilePaused() {
        var cadence = PollCadence()
        let next = cadence.next(base: 20, idle: true, paused: true, budget: budget(0, resetIn: 120), now: start)
        XCTAssertEqual(next.seconds, 120)
    }

    func testTightestPicksTheSmallestShareLeft() {
        let tightest = PollCadence.tightest([budget(4000), budget(100, of: 1000), budget(2000)])
        XCTAssertEqual(tightest?.remaining, 100)
        XCTAssertNil(PollCadence.tightest([]))
    }
}
