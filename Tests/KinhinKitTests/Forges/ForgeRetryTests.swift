import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ForgeRetryTests: XCTestCase {
    /// GitHub and Gitea served by one engine (same shape as DualForgeTests).
    private func dualConfig() throws -> KinhinConfig {
        try ConfigLoader.parse(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
              - name: gitea
                forge: gitea
                scope: "team/repo"
                instance: "https://git.example.com"
            labels: [a]
            """)
    }

    private func makeDual(github: FakeGitHub) throws -> FleetEngine {
        let cfg = try dualConfig()
        // Every account has a token stored (the Keychain is not under test
        // here; the GitHub client's permission flag is).
        let engine = FleetEngine(
            config: cfg, github: github, tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            dependencies: .init(tokenLoader: { _, _ in "tok" }))
        engine.forgeState.withLock { $0.byPlatform["gitea"] = DualForgeTests.FakeGitea() }
        return engine
    }

    func testGitHubReattachesOnceItRecovers() async throws {
        let github = FakeGitHub()
        github.permissionDenied = true
        let engine = try makeDual(github: github)
        await engine.start()
        XCTAssertNil(engine.forges["github"], "dropped at startup")

        // Still broken: retry keeps it detached and keeps the reason visible.
        await engine.retryDetachedForgesIfDue(ignoreBackoff: true)
        XCTAssertNil(engine.forges["github"])
        let stillBroken = await engine.status().lastError
        XCTAssertTrue(stillBroken?.hasPrefix("account 'github':") ?? false)

        // Recovered: the next retry re-attaches it and clears the error.
        github.permissionDenied = false
        await engine.retryDetachedForgesIfDue(ignoreBackoff: true)
        XCTAssertNotNil(engine.forges["github"], "GitHub is serving again without a restart")
        let cleared = await engine.status().lastError
        XCTAssertNil(cleared)
        await engine.stop()
    }

    func testRetryRespectsBackoff() async throws {
        let github = FakeGitHub()
        github.permissionDenied = true
        let engine = try makeDual(github: github)
        await engine.start()
        XCTAssertNil(engine.forges["github"], "the failed account is detached")
        let callsAfterStart = github.registrationTokenCalls

        github.permissionDenied = false
        await engine.retryDetachedForgesIfDue(now: Date())  // too soon
        XCTAssertEqual(github.registrationTokenCalls, callsAfterStart, "no probe before the backoff elapses")
        XCTAssertNil(engine.forges["github"])

        await engine.retryDetachedForgesIfDue(now: Date().addingTimeInterval(31))
        XCTAssertNotNil(engine.forges["github"], "after 30s the retry runs")
        await engine.stop()
    }

    func testBackoffDoublesAndCaps() {
        var state = ForgeRetryState()
        let now = Date()
        state.scheduleNext(after: ForgeRetryState.initialDelay, now: now)
        XCTAssertEqual(state.delay, 30)
        for expected in [60.0, 120, 240, 300, 300] {
            state.backOff(now: now)
            XCTAssertEqual(state.delay, expected)
        }
    }

    func testNothingRetriesWhenAllForgesAreAttached() async throws {
        let github = FakeGitHub()
        let engine = try makeDual(github: github)
        await engine.start()
        let calls = github.registrationTokenCalls
        await engine.retryDetachedForgesIfDue(ignoreBackoff: true)
        XCTAssertEqual(github.registrationTokenCalls, calls)
        await engine.stop()
    }
}

/// Tart is optional when a Linux runtime is configured.
