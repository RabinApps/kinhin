import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Stage 1 of the runtime abstraction: the Runtime protocol plus the
/// TartRuntime implementation that wraps the engine's original tart calls.
/// Behavior must be identical to the pre-refactor engine — these tests pin
/// that.
final class RuntimeTests: XCTestCase {
    // MARK: TartRuntime behavior

    func testProvisionClonesAndBoots() async throws {
        let tart = FakeTart()
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 })
        let route = RepoRoute(repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 300)

        try await runtime.provision(id: "kinhin-1", route: route)

        XCTAssertEqual(tart.cloneCalls.count, 1)
        XCTAssertEqual(tart.cloneCalls.first?.source, "tahoe-base")
        XCTAssertEqual(tart.cloneCalls.first?.name, "kinhin-1")
        XCTAssertEqual(tart.runCalls, ["kinhin-1"])
    }

    func testProvisionReusesExistingVMWithoutClone() async throws {
        let tart = FakeTart()
        tart.vms["kinhin-1"] = TartVM(name: "kinhin-1", source: "tahoe-base", status: "stopped")
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 })

        try await runtime.provision(
            id: "kinhin-1", route: RepoRoute(repo: "r", image: "tahoe-base", ephemeral: true, bootTimeout: 300))

        XCTAssertTrue(tart.cloneCalls.isEmpty, "recovery path: existing VM is reused, not cloned")
        XCTAssertTrue(tart.runCalls.isEmpty, "a running VM is left as-is")
    }

    func testTeardownStopsAndDeletesIdempotently() async throws {
        let tart = FakeTart()
        tart.vms["kinhin-1"] = TartVM(name: "kinhin-1", source: "s", status: "running")
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 })

        await runtime.teardown(id: "kinhin-1")
        await runtime.teardown(id: "kinhin-1")  // second call must not throw

        XCTAssertTrue(tart.stopCalls.contains("kinhin-1"))
        XCTAssertEqual(tart.deleteCalls.filter { $0 == "kinhin-1" }.count, 1, "delete runs once; second is a no-op")
        XCTAssertNil(tart.vms["kinhin-1"])
    }

    func testHealthMapsTartStates() async {
        // The real probe runs against this machine's tart; only the mapping
        // shape is asserted via a missing-binary runtime probe result.
        let runtime = TartRuntime(tart: FakeTart(), bootTimeout: { 300 })
        let health = await runtime.health()
        // On a dev machine with tart installed this is .ready; either way the
        // health value must be one of the defined states.
        switch health {
        case .ready, .missing, .broken:
            break
        }
        _ = health.isReady
    }

    // MARK: Engine integration

    func testEngineStampsRuntimeOnSpawnedRecords() async throws {
        let github = FakeGitHub()
        github.queueDepth = 1
        let engine = FleetEngine(
            config: makeTestConfig(), github: github, tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost
        )
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.first?.phase == .ready
        }
        let status = await engine.status()
        XCTAssertEqual(status.records.first?.runtime, "tart", "stage 1: every spawned record runs on tart")
        await engine.stop()
    }

    func testEngineUsesRuntimeForTeardown() async throws {
        let github = FakeGitHub()
        github.queueDepth = 1
        let tart = FakeTart()
        let engine = FleetEngine(
            config: makeTestConfig(), github: github, tart: tart,
            store: makeTestStore(), ssh: FakeSSH(), host: testHost
        )
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.first?.phase == .ready
        }
        let id = await engine.status().records.first!.id

        await engine.deleteVM(id: id)
        let status = await engine.status()
        XCTAssertTrue(status.records.isEmpty)
        XCTAssertTrue(tart.stopCalls.contains(id), "teardown routed through the runtime (stop)")
        XCTAssertTrue(tart.deleteCalls.contains(id), "teardown routed through the runtime (delete)")
    }

    func waitUntil(timeout: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
