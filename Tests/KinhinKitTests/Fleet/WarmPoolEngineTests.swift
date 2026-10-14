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

    func testAnImagesWarmPoolClonesFromThatImage() async throws {
        let tart = FakeTart()
        // The prepared `images:` entry: its VM exists, so the warm pool can clone it.
        try await tart.clone(source: "tahoe-base", to: "xcode")
        var config = makeTestConfig()
        config.images = [.init(name: "xcode", labels: ["xcode"], warmPool: 1)]
        let engine = FleetEngine(
            config: config, github: FakeGitHub(), tart: tart, store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, exitWatchInterval: .milliseconds(20)))

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await engine.status().records.contains { $0.phase == .warm } }

        let status = await engine.status()
        let warm = try XCTUnwrap(status.records.first { $0.phase == .warm })
        XCTAssertEqual(warm.image, "xcode")
        XCTAssertEqual(tart.cloneCalls.last?.source, "xcode", "the warm instance is cloned from its own image")
    }

    /// An engine whose `xcode` image keeps one warm VM. The image is prepared up front (a clone of the base
    /// stands in for `kinhin image prepare`), so the warm pool has something to clone.
    private func makeXcodeEngine(tart: FakeTart, github: FakeGitHub) async throws -> FleetEngine {
        try await tart.clone(source: "tahoe-base", to: "xcode")
        var config = makeTestConfig()
        config.images = [.init(name: "xcode", labels: ["xcode"], warmPool: 1)]
        return FleetEngine(
            config: config, github: github, tart: tart, store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, exitWatchInterval: .milliseconds(20)))
    }

    func testAnXcodeJobClaimsTheXcodeWarmInstance() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = try await makeXcodeEngine(tart: tart, github: github)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await engine.status().records.contains { $0.phase == .warm } }
        let warmStatus = await engine.status()
        let warmID = try XCTUnwrap(warmStatus.records.first { $0.phase == .warm }?.id)
        let clonesBeforeJob = tart.cloneCalls.count

        // A queued job that asks for the xcode label, routed to the xcode image.
        github.queueExtraLabels = ["xcode"]
        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.first(where: { $0.id == warmID })?.phase == .ready
        }

        let claimedStatus = await engine.status()
        let claimed = try XCTUnwrap(claimedStatus.records.first { $0.id == warmID })
        XCTAssertEqual(claimed.image, "xcode")
        XCTAssertNotNil(claimed.platform, "claiming binds the warm instance to the account")
        XCTAssertEqual(tart.cloneCalls.count, clonesBeforeJob, "the job claims the warm VM instead of cloning")
    }

    func testABaseJobLeavesTheXcodeWarmInstanceAlone() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = try await makeXcodeEngine(tart: tart, github: github)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { await engine.status().records.contains { $0.phase == .warm } }
        let warmStatus = await engine.status()
        let warmID = try XCTUnwrap(warmStatus.records.first { $0.phase == .warm }?.id)

        // A plain job, with no xcode label: it runs on the base image and must not take the xcode VM.
        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { tart.cloneCalls.contains { $0.source == "tahoe-base" } }

        let status = await engine.status()
        XCTAssertEqual(status.records.first { $0.id == warmID }?.phase, .warm, "the xcode warm VM stays unclaimed")
    }
}
