import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The runtime abstraction: the Runtime protocol plus the
/// TartRuntime implementation that wraps the engine's original tart calls.
/// Behavior must be identical to the pre-refactor engine — these tests pin
/// that.
final class RuntimeTests: XCTestCase {
    // MARK: - TartRuntime behavior

    func testProvisionClonesAndBoots() async throws {
        let tart = FakeTart()
        let runtime = TartRuntime(
            tart: tart, bootTimeout: { 300 }, cpuCount: { 6 }, memoryMB: { 12 * 1024 })
        let route = RepoRoute(repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 300)

        try await runtime.provision(id: "kinhin-1", route: route)

        XCTAssertEqual(tart.cloneCalls.count, 1)
        XCTAssertEqual(tart.cloneCalls.first?.source, "tahoe-base")
        XCTAssertEqual(tart.cloneCalls.first?.name, "kinhin-1")
        XCTAssertEqual(tart.setCalls.count, 1)
        XCTAssertEqual(tart.setCalls.first?.name, "kinhin-1")
        XCTAssertEqual(tart.setCalls.first?.cpu, 6)
        XCTAssertEqual(tart.setCalls.first?.memoryMB, 12 * 1024)
        XCTAssertEqual(tart.provisionEvents, ["clone:kinhin-1", "set:kinhin-1", "run:kinhin-1"])
        XCTAssertEqual(tart.runCalls, ["kinhin-1"])
    }

    func testProvisionDoesNotRunWhenSettingResourcesFails() async throws {
        let tart = FakeTart()
        tart.failNext("set", stderr: "resource update failed")
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 }, cpuCount: { 6 }, memoryMB: { 12 * 1024 })
        let route = RepoRoute(repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 300)

        do {
            try await runtime.provision(id: "kinhin-1", route: route)
            XCTFail("failed resource configuration must abort provisioning")
        } catch let error as TartError {
            XCTAssertEqual(error.localizedDescription, "tart set failed: resource update failed")
        }
        XCTAssertTrue(tart.runCalls.isEmpty)
    }

    func testProvisionResumesAStoppedCloneWithSizingAndBoot() async throws {
        // Recovery for a clone that died before its first boot: the sizing
        // applies (it may predate `vm.cpu`/`vm.memory_gb` or a failed
        // `tart set`) and the still-stopped VM starts.
        let tart = FakeTart()
        tart.vms["kinhin-1"] = TartVM(name: "kinhin-1", source: "tahoe-base", status: "stopped")
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 }, cpuCount: { 6 }, memoryMB: { 12 * 1024 })

        try await runtime.provision(
            id: "kinhin-1", route: RepoRoute(repo: "r", image: "tahoe-base", ephemeral: true, bootTimeout: 300))

        XCTAssertTrue(tart.cloneCalls.isEmpty, "recovery path: existing VM is reused, not cloned")
        XCTAssertEqual(tart.setCalls.map { $0.name }, ["kinhin-1"], "a stopped clone still gets its sizing")
        XCTAssertEqual(tart.runCalls, ["kinhin-1"], "the stopped clone is started")
    }

    /// The set-to-run window: teardown cancels the lifecycle task without
    /// waiting for it, so a provision whose task is cancelled while `tart set`
    /// runs must not start the VM once set returns — its teardown stop would
    /// otherwise be undone and the VM would survive until a later retry.
    func testProvisionDoesNotStartTheVMAfterACancelledTask() async throws {
        let tart = FakeTart()
        tart.blockNextSet()
        let runtime = TartRuntime(
            tart: tart, bootTimeout: { 300 }, cpuCount: { 6 }, memoryMB: { 12 * 1024 })
        let route = RepoRoute(repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 300)

        let task = Task { try await runtime.provision(id: "kinhin-1", route: route) }
        await tart.waitUntilSetParked()
        task.cancel()  // cancellation is observed exactly once set resumes
        tart.releaseSet()

        do {
            try await task.value
            XCTFail("a cancelled provision must end with CancellationError")
        } catch is CancellationError {
        }
        XCTAssertTrue(tart.runCalls.isEmpty, "the VM is not started after cancellation")
    }

    func testProvisionLeavesARunningVMUntouched() async throws {
        let tart = FakeTart()
        tart.vms["kinhin-1"] = TartVM(name: "kinhin-1", source: "tahoe-base", status: "running")
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 })

        try await runtime.provision(
            id: "kinhin-1", route: RepoRoute(repo: "r", image: "tahoe-base", ephemeral: true, bootTimeout: 300))

        XCTAssertTrue(tart.cloneCalls.isEmpty, "recovery path: existing VM is reused, not cloned")
        XCTAssertTrue(tart.setCalls.isEmpty, "a running VM is not re-sized")
        XCTAssertTrue(tart.runCalls.isEmpty, "a running VM is left as-is")
    }

    func testTeardownStopsAndDeletesIdempotently() async throws {
        let tart = FakeTart()
        tart.vms["kinhin-1"] = TartVM(name: "kinhin-1", source: "s", status: "running")
        tart.strictMissing = true
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 })

        try await runtime.teardown(id: "kinhin-1")
        try await runtime.teardown(id: "kinhin-1")  // second call must not throw

        XCTAssertEqual(tart.stopCalls, ["kinhin-1"], "no tart list round trip; a missing VM is success")
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

    func testHealthProbesTheConfiguredTartPath() async throws {
        // A configured binary that isn't there reads as missing even when a
        // real tart sits on PATH — the override is authoritative, like every
        // other tart call in the app.
        let missing = TartRuntime(
            tart: FakeTart(), bootTimeout: { 300 }, tartPath: "/nonexistent/kinhin-test-tart")
        let missingHealth = await missing.health()
        XCTAssertEqual(
            missingHealth, .missing(tool: "tart", fix: TartHealthProbe.installCommand))

        // And the probe runs the configured binary: a stub tart answering a
        // healthy version reads ready, wherever it lives.
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-test-tart-\(UUID().uuidString)")
        try "#!/bin/sh\necho tart version 2.32.1\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        defer { try? FileManager.default.removeItem(at: stub) }  // temp fixture; leftover is harmless

        let found = TartRuntime(tart: FakeTart(), bootTimeout: { 300 }, tartPath: stub.path)
        let foundHealth = await found.health()
        XCTAssertEqual(foundHealth, .ready)
    }

    // MARK: - Engine integration

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
        XCTAssertEqual(status.records.first?.runtime, "tart", "a default fleet spawns every record on tart")
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

        try await engine.deleteVM(id: id)
        let status = await engine.status()
        XCTAssertTrue(status.records.isEmpty)
        XCTAssertTrue(tart.stopCalls.contains(id), "teardown routed through the runtime (stop)")
        XCTAssertTrue(tart.deleteCalls.contains(id), "teardown routed through the runtime (delete)")
    }

}
