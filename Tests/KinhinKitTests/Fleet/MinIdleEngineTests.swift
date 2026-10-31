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
}
