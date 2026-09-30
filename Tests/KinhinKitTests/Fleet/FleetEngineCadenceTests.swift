import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The engine's side of the adaptive poll cadence: what a pass reports, how
/// a wait is cut short, and which reads a low API budget drops.
final class FleetEngineCadenceTests: XCTestCase {
    func makeEngine(github: FakeGitHub, config: KinhinConfig = makeTestConfig()) -> FleetEngine {
        FleetEngine(
            config: config, github: github, tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost)
    }

    func testAnEmptyFleetWithNoQueueIsIdle() async throws {
        let engine = makeEngine(github: FakeGitHub())
        let outcome = try await engine.reconcileOnce()
        XCTAssertTrue(outcome.idle)
    }

    func testQueuedDemandIsNotIdle() async throws {
        let github = FakeGitHub()
        github.queueDepth = 1
        var config = makeTestConfig()
        config.maxRunners = 0  // observe the demand without spawning
        let engine = makeEngine(github: github, config: config)
        let outcome = try await engine.reconcileOnce()
        XCTAssertFalse(outcome.idle)
    }

    /// Paused passes mask the queue, so they cannot vouch for idleness.
    func testAPausedPassIsNeverIdle() async throws {
        let engine = makeEngine(github: FakeGitHub())
        await engine.setPaused(true)
        let outcome = try await engine.reconcileOnce()
        XCTAssertFalse(outcome.idle)
    }

    func testPollSoonCutsTheWaitShort() async throws {
        let engine = makeEngine(github: FakeGitHub())
        engine.pollSoon()
        let clock = ContinuousClock()
        let elapsed = try await clock.measure { try await engine.waitForNextPass(seconds: 60) }
        XCTAssertLessThan(elapsed, .seconds(2))
        XCTAssertFalse(engine.runState.withLock { $0.pollNow }, "the request is consumed")
    }

    func testResumingRequestsAPassNow() async {
        let engine = makeEngine(github: FakeGitHub())
        await engine.setPaused(true)
        XCTAssertFalse(engine.runState.withLock { $0.pollNow })
        await engine.setPaused(false)
        XCTAssertTrue(engine.runState.withLock { $0.pollNow })
    }

    func testReloadRequestsAPassNow() {
        let engine = makeEngine(github: FakeGitHub())
        engine.applyReloaded(config: makeTestConfig(), host: testHost)
        XCTAssertTrue(engine.runState.withLock { $0.pollNow })
    }

    func testLowBudgetDropsRunningAttributionButKeepsDemand() async throws {
        let github = FakeGitHub()
        let engine = makeEngine(github: github)
        try await engine.reconcileOnce()
        XCTAssertEqual(github.runningJobsCallCount, 1)

        github.rateLimit = ForgeRateLimit(remaining: 10, limit: 5000, resetAt: Date().addingTimeInterval(600))
        let queuedBefore = github.queuedJobsCallCount
        try await engine.reconcileOnce()
        XCTAssertEqual(github.runningJobsCallCount, 1, "attribution is cosmetic: skipped on a low budget")
        XCTAssertEqual(github.queuedJobsCallCount, queuedBefore + 1, "demand is still read")
    }
}
