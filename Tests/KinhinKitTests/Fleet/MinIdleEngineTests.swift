import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `min_idle` through a real reconcile pass: the floor's runner is cloned from its image and registered with
/// nothing queued, and a floor on an image that is not prepared is skipped, before the plan sizes anything, instead
/// of failing clones.
final class MinIdleEngineTests: XCTestCase {
    private func makeEngine(
        tart: FakeTart, github: FakeGitHub, minIdle: Int, configure: (inout KinhinConfig) -> Void = { _ in }
    ) -> FleetEngine {
        var config = makeTestConfig()
        config.images = [.init(name: "xcode", labels: ["xcode"], minIdle: minIdle)]
        configure(&config)
        return FleetEngine(
            config: config, github: github, tart: tart, store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, exitWatchInterval: .milliseconds(20)))
    }

    func testAnImagesFloorRegistersAnIdleRunnerWithNothingQueued() async throws {
        let tart = FakeTart()
        // The prepared `images:` entry: a clone of the base stands in for `kinhin image prepare`.
        try await tart.clone(source: "tahoe-base", to: "xcode")
        let github = FakeGitHub()
        let engine = makeEngine(tart: tart, github: github, minIdle: 1)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.contains { $0.image == "xcode" && $0.phase == .ready }
        }

        let status = await engine.status()
        let record = try XCTUnwrap(status.records.first { $0.image == "xcode" })
        XCTAssertEqual(record.platform, "github", "an idle floor runner is registered, unlike a warm VM")
        XCTAssertNil(record.pooled)
        XCTAssertEqual(github.queueDepth, 0)
        XCTAssertEqual(github.registrationTokenCalls, 1)
        XCTAssertEqual(tart.cloneCalls.last?.source, "xcode", "the runner is cloned from its own image")
    }

    func testAnUnpreparedImagesFloorIsSkipped() async throws {
        let tart = FakeTart()
        let engine = makeEngine(tart: tart, github: FakeGitHub(), minIdle: 1)

        try await engine.reconcileOnce()

        let status = await engine.status()
        XCTAssertTrue(status.records.allSatisfy { $0.image != "xcode" }, "no runner for an unprepared image")
        XCTAssertTrue(tart.cloneCalls.allSatisfy { $0.source != "xcode" }, "nothing clones the unprepared image")
    }

    func testAnUnpreparedImagesFloorDoesNotHoldBackTheWarmPool() async throws {
        let tart = FakeTart()
        let engine = makeEngine(tart: tart, github: FakeGitHub(), minIdle: 1) { $0.warmPool = 1 }

        try await engine.reconcileOnce()

        let records = await engine.status().records
        XCTAssertTrue(records.allSatisfy { $0.image != "xcode" }, "no runner for an unprepared image")
        XCTAssertEqual(
            records.filter { $0.pooled == true && $0.image == nil }.count, 1,
            "the base image's warm pool still tops up: the skipped floor planned no slot")
    }

    func testAnUnpreparedImagesFloorTakesNoRoomFromAPreparedOne() async throws {
        let tart = FakeTart()
        try await tart.clone(source: "tahoe-base", to: "xcode")
        // "aaa" sorts first among the floors, so planned without its prepared state it would take the only slot.
        let engine = makeEngine(tart: tart, github: FakeGitHub(), minIdle: 1) {
            $0.maxRunners = 1
            $0.images.insert(.init(name: "aaa", labels: ["aaa"], minIdle: 1), at: 0)
        }

        try await engine.reconcileOnce()

        let records = await engine.status().records
        XCTAssertEqual(records.map(\.image), ["xcode"], "only the prepared image's floor is planned")
    }

    func testNoFloorStartsNothing() async throws {
        let tart = FakeTart()
        try await tart.clone(source: "tahoe-base", to: "xcode")
        let engine = makeEngine(tart: tart, github: FakeGitHub(), minIdle: 0)
        let clonesBefore = tart.cloneCalls.count

        try await engine.reconcileOnce()

        let status = await engine.status()
        XCTAssertTrue(status.records.isEmpty)
        XCTAssertEqual(tart.cloneCalls.count, clonesBefore)
    }

    // MARK: - Reload

    func testReloadedFloorsAreReadFromTheSwappedSnapshot() throws {
        var config = makeTestConfig()
        config.container = .init(image: "linux", cpus: 2, memoryGB: 4)
        config.docker = .init(image: "docker-base")
        let engine = FleetEngine(
            config: config, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost, dependencies: .init(tokenLoader: { _, _ in "t" }, exitWatchInterval: .milliseconds(20)))
        XCTAssertTrue(engine.minIdleTargets(snapshot: engine.router.snapshot).isEmpty)

        var edited = config
        edited.imageMinIdle = 1
        edited.container?.minIdle = 1
        edited.docker?.minIdle = 1
        engine.applyReloaded(config: edited, host: testHost)

        XCTAssertEqual(
            engine.minIdleTargets(snapshot: engine.router.snapshot),
            [
                .init(runtime: .tart): 1, .init(runtime: .appleContainer, pool: ""): 1,
                .init(runtime: .docker): 1,
            ])

        edited.container?.pools = [.init(name: "big", image: "linux", minIdle: 2)]
        edited.container?.minIdle = 0
        edited.imageMinIdle = 0
        engine.applyReloaded(config: edited, host: testHost)
        XCTAssertEqual(
            engine.minIdleTargets(snapshot: engine.router.snapshot),
            [.init(runtime: .appleContainer, pool: "big"): 2, .init(runtime: .docker): 1])
    }

    func testTheNextPassTopsUpToAReloadedFloor() async throws {
        let tart = FakeTart()
        let engine = makeEngine(tart: tart, github: FakeGitHub(), minIdle: 0)
        try await engine.reconcileOnce()
        let before = await engine.status().records
        XCTAssertTrue(before.isEmpty, "no floor, nothing queued: nothing runs")

        var edited = engine.activeConfig
        edited.imageMinIdle = 1
        engine.applyReloaded(config: edited, host: testHost)
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.filter { $0.image == nil && $0.phase == .ready }.count == 1
        }

        edited.imageMinIdle = 2
        engine.applyReloaded(config: edited, host: testHost)
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            await engine.status().records.filter { $0.image == nil && $0.phase == .ready }.count == 2
        }
    }

    func testDisabledPoolsKeepNoFloorEvenAfterAReload() throws {
        var config = makeTestConfig()
        config.container = .init(image: "linux", cpus: 2, memoryGB: 4)
        config.container?.pools = [
            .init(name: "on", image: "linux", minIdle: 1),
            .init(name: "off", image: "linux", minIdle: 1, enabled: false),
        ]
        config.docker = .init(image: "docker-base", minIdle: 1, enabled: false)
        let engine = FleetEngine(
            config: config, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost, dependencies: .init(tokenLoader: { _, _ in "t" }, exitWatchInterval: .milliseconds(20)))
        engine.applyReloaded(config: config, host: testHost)
        XCTAssertEqual(
            engine.minIdleTargets(snapshot: engine.router.snapshot), [.init(runtime: .appleContainer, pool: "on"): 1])
    }
}
