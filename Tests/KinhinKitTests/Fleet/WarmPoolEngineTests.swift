import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class WarmPoolEngineTests: XCTestCase {
    private func makeEngine(tart: FakeTart, github: FakeGitHub, ssh: FakeSSH, warmPool: Int) -> FleetEngine {
        var config = makeTestConfig()
        config.warmPool = warmPool
        return FleetEngine(
            config: config, github: github, tart: tart, store: makeTestStore(), ssh: ssh, host: testHost,
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, exitWatchInterval: .milliseconds(20)))
    }

    func testIdleFleetBootsAWarmInstanceWithoutRegisteringIt() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH(), warmPool: 1)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await engine.status().records.first?.phase == .warm }

        XCTAssertEqual(tart.cloneCalls.count, 1)
        XCTAssertEqual(github.registrationTokenCalls, 0, "a warm instance has no forge identity")
        let status = await engine.status()
        let record = try XCTUnwrap(status.records.first)
        XCTAssertNil(record.platform)
        XCTAssertNotNil(record.ip)
    }

    func testAJobClaimsTheWarmInstanceInsteadOfCloning() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH(), warmPool: 1)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await engine.status().records.first?.phase == .warm }
        let warmStatus = await engine.status()
        let warmID = try XCTUnwrap(warmStatus.records.first?.id)

        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.first(where: { $0.id == warmID })?.phase == .ready
        }

        let finalStatus = await engine.status()
        let claimed = try XCTUnwrap(finalStatus.records.first(where: { $0.id == warmID }))
        XCTAssertNotNil(claimed.platform, "claiming binds the instance to the account")
        XCTAssertEqual(github.registrationTokenCalls, 1)
        XCTAssertEqual(tart.cloneCalls.filter { $0.name == warmID }.count, 1, "the claimed VM was cloned exactly once")
        XCTAssertEqual(tart.runCalls.count, 1, "no second boot for the job")
    }
}
