import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class FleetEngineTests: XCTestCase {
    func makeEngine(
        config: KinhinConfig? = nil,
        tart: FakeTart,
        github: FakeGitHub,
        ssh: FakeSSH
    ) -> FleetEngine {
        FleetEngine(
            config: config ?? makeTestConfig(),
            github: github,
            tart: tart,
            store: makeTestStore(),
            ssh: ssh,
            host: testHost
        )
    }

    func testScaleUpSpawnsVMAndRegistersRunner() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let ssh = FakeSSH()
        let engine = makeEngine(tart: tart, github: github, ssh: ssh)

        github.queueDepth = 1
        try await engine.reconcileOnce()

        // Cloning is synchronous inside reconcileOnce's spawn; the lifecycle
        // task then boots and registers. Poll until stable.
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.activeCount == 1
        }
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.first?.phase == .ready
        }
        let status = await engine.status()
        XCTAssertEqual(status.desired, 1)
        XCTAssertEqual(tart.cloneCalls.count, 1)
        XCTAssertEqual(github.registrationTokenCalls, 1)
    }

    func testQueueZeroCreatesNothing() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())

        await engine.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await engine.stop()

        let status = await engine.status()
        XCTAssertEqual(status.desired, 0)
        XCTAssertTrue(tart.cloneCalls.isEmpty)
    }

    func testJobCompletionDeletesVM() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let ssh = FakeSSH()
        let engine = makeEngine(tart: tart, github: github, ssh: ssh)

        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.first?.phase == .ready
        }

        // Simulate the runner being picked up, then deregistering (ephemeral).
        let vmName = await engine.status().records.first!.id
        github.register(name: vmName, busy: true)
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.first(where: { $0.id == vmName })?.phase == .busy
        }
        github.deregister(name: vmName)
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.isEmpty
        }
        try await waitUntil(timeout: 10) {
            tart.deleteCalls.contains(vmName)
        }
    }

    func testFailedCloneSurfacesError() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 1
        tart.failNextClone = true
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.first(where: { $0.phase == .failed }) != nil
        }
        // Failed VMs are cleaned up on the next pass. Drain the queue first so
        // the scaler does not legitimately spawn a replacement VM.
        github.queueDepth = 0
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.isEmpty
        }
    }

    func testRecoveryAdoptsOrphanVMAndDropsStaleRecord() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())

        // A VM exists in tart with no record (engine crashed before persisting).
        tart.vms["kinhin-orphan"] = TartVM(name: "kinhin-orphan", source: "base", status: "running")
        // A stale record whose VM is gone.
        engine.store.upsert(VMRecord(id: "kinhin-gone", phase: .ready))

        await engine.start()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            let ids = status.records.map { $0.id }
            return ids.contains("kinhin-orphan") && !ids.contains("kinhin-gone")
        }
        await engine.stop()
    }

    func testCapacityCapLimitsSpawns() async throws {
        var cfg = makeTestConfig()
        cfg.maxRunners = 5
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 5
        // testHost: 12 cores, 32 GB -> 4-cpu/8-gb VMs cap at (12-2)/4 = 2
        let engine = FleetEngine(
            config: cfg, github: github, tart: tart,
            store: makeTestStore(), ssh: FakeSSH(), host: testHost
        )
        try await engine.reconcileOnce()
        let status = await engine.status()
        XCTAssertEqual(status.desired, 2)
    }

    // MARK: Many-to-one (runners_per_vm)

    /// rpv=2, queue of 4 → 2 VMs; each VM registers 2 runners; the VM dies
    /// only when BOTH runners deregister.
    func testManyToOneScalesVMsByDensityAndWaitsForAllRunners() async throws {
        var cfg = makeTestConfig()
        cfg.maxRunners = 4
        cfg.runnersPerVM = 2
        let tart = FakeTart()
        let github = FakeGitHub()
        let ssh = FakeSSH()
        let engine = FleetEngine(
            config: cfg, github: github, tart: tart,
            store: makeTestStore(), ssh: ssh, host: testHost
        )

        github.queueDepth = 4
        try await engine.reconcileOnce()
        let status = await engine.status()
        XCTAssertEqual(status.desired, 2, "4 jobs at rpv=2 need 2 VMs")
        XCTAssertEqual(status.jobCapacity, 4, "2 VMs × rpv 2")

        try await waitUntil(timeout: 15) {
            let s = await engine.status()
            return s.records.filter { $0.phase == .ready }.count == 2
        }
        // One registration script per VM; each mentions both indexed runners.
        XCTAssertEqual(ssh.scripts.count, 2)
        for script in ssh.scripts {
            XCTAssertTrue(script.contains("--name '") && script.contains("-r1"))
            XCTAssertTrue(script.contains("-r2"))
        }

        // r1 goes busy while r2 sits idle-registered; r1 finishing and
        // deregistering must NOT delete the VM — r2 still needs it.
        let vm1 = (await engine.status().records.map(\.id)).sorted()[0]
        github.register(name: "\(vm1)-r1", busy: true)
        github.register(name: "\(vm1)-r2", busy: false)
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first(where: { $0.id == vm1 })?.phase == .busy
        }
        github.deregister(name: "\(vm1)-r1")
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first(where: { $0.id == vm1 })?.phase == .ready
        }
        let survived = await engine.status().records.first(where: { $0.id == vm1 })
        XCTAssertNotNil(survived, "VM must survive partial deregistration")
        XCTAssertEqual(survived?.phase, .ready, "r2 still idle-registered")

        // Last runner deregisters → VM is deleted.
        github.deregister(name: "\(vm1)-r2")
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first(where: { $0.id == vm1 }) == nil
        }
        try await waitUntil(timeout: 10) { tart.deleteCalls.contains(vm1) }
    }

    func testDeleteSweepsAllIndexedRunnersFromGitHub() async throws {
        var cfg = makeTestConfig()
        cfg.runnersPerVM = 2
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = makeEngine(config: cfg, tart: tart, github: github, ssh: FakeSSH())

        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first?.phase == .ready
        }
        let vm = await engine.status().records.first!.id
        // Simulate lingering registrations on the GitHub side.
        github.register(name: "\(vm)-r1", busy: false)
        github.register(name: "\(vm)-r2", busy: false)

        await engine.deleteVMRecord(id: vm, reason: "test sweep")
        try await waitUntil(timeout: 10) { github.deletedRunnerIDs.count == 2 }
    }

    // MARK: Helpers

    func waitUntil(timeout: TimeInterval, _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
