import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class FleetEdgeTests: XCTestCase {
    /// Free disk the disk guard sees (tests move it between passes).
    private final class FreeDisk: Sendable {
        private let gb = Mutex(testHost.freeDiskGB)
        var value: Int { gb.withLock { $0 } }
        func set(_ value: Int) { gb.withLock { $0 = value } }
    }
    private let freeDisk = FreeDisk()

    func makeEngine(config: KinhinConfig? = nil, tart: FakeTart, github: FakeGitHub, ssh: FakeSSH) -> FleetEngine {
        let freeDisk = self.freeDisk
        return FleetEngine(
            config: config ?? makeTestConfig(),
            github: github,
            tart: tart,
            store: makeTestStore(),
            ssh: ssh,
            host: testHost,
            dependencies: .init(
                hostProbe: {
                    HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: freeDisk.value, arm64: true)
                }, exitWatchInterval: .milliseconds(20))
        )
    }

    // MARK: - Disk-pressure guard

    func testDiskPressureHoldsSpawnsAndSurfacesLastError() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 2
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())
        // 15 GB free < 50 GB default VM footprint + 10 GB reserve.
        freeDisk.set(15)

        try await engine.reconcileOnce()
        let status = await engine.status()
        XCTAssertEqual(status.desired, 2, "desired is computed from the queue")
        XCTAssertTrue(tart.cloneCalls.isEmpty, "no VM may spawn under disk pressure")
        let lastError = status.lastError ?? ""
        XCTAssertTrue(lastError.contains("disk pressure"), "\(lastError)")
        XCTAssertTrue(
            status.diskPressureNotice?.contains("disk pressure") ?? false,
            "the Fleet tab banner rides the same episode")

        // Freeing disk lets the next pass spawn again (desired = 2 → both clone).
        freeDisk.set(200)
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { tart.cloneCalls.count == 2 }
        let eased = await engine.status()
        XCTAssertNil(eased.diskPressureNotice, "the banner clears once pressure eases")
    }

    /// One host probe per pass, whatever the burst size; each planned VM
    /// subtracts its own share, so a burst still cannot overrun the disk.
    func testHostIsProbedOncePerPassAndPlannedVMsConsumeDisk() async throws {
        let probes = Mutex(0)
        var cfg = makeTestConfig()
        cfg.maxRunners = 5
        cfg.diskGB = 30  // 30 + 10 reserve = 40 needed per spawn
        let github = FakeGitHub()
        github.queueDepth = 5
        let tart = FakeTart()
        let engine = FleetEngine(
            config: cfg, github: github, tart: tart, store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            dependencies: .init(
                hostProbe: {
                    probes.withLock { $0 += 1 }
                    // Room for one (needs 40): after it 30 GB remain, short of the next one's 40.
                    return HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 60, arm64: true)
                }, spawnStagger: .zero, exitWatchInterval: .milliseconds(20)))

        try await engine.reconcileOnce()
        XCTAssertEqual(probes.withLock { $0 }, 1, "probed once for the whole pass")
        XCTAssertEqual(engine.store.all.count, 1, "the first VM's share is subtracted: the second is held")
        let status = await engine.status()
        XCTAssertTrue(status.lastError?.contains("disk pressure") ?? false)
    }

    func testDiskGuardCountsExplicitDiskGB() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 1
        var cfg = makeTestConfig()
        cfg.diskGB = 30  // explicit footprint: 30 + 10 reserve = 40 needed
        let engine = makeEngine(config: cfg, tart: tart, github: github, ssh: FakeSSH())
        freeDisk.set(39)

        try await engine.reconcileOnce()
        var status = await engine.status()
        XCTAssertTrue(status.lastError?.contains("disk pressure") ?? false)
        XCTAssertTrue(tart.cloneCalls.isEmpty)

        // 41 GB free clears 40 needed.
        freeDisk.set(41)
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { tart.cloneCalls.count == 1 }
        status = await engine.status()
        XCTAssertNil(status.lastError ?? nil, "the guard clears once spawns resume")
    }

    func testPauseHoldsFleetAndSkipsQueuePolling() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 3
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())

        await engine.setPaused(true)
        try await engine.reconcileOnce()
        let status = await engine.status()
        XCTAssertTrue(status.paused)
        XCTAssertEqual(status.queueDepth, 0, "paused engine must not poll GitHub")
        XCTAssertEqual(status.desired, 0)
        XCTAssertTrue(tart.cloneCalls.isEmpty)

        await engine.setPaused(false)
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.desired == 2 && s.queueDepth == 3  // max_runners default = 2
        }
        try await waitUntil(timeout: 15) {
            let s = await engine.status()
            return s.records.filter { $0.phase == .ready }.count == 2
        }
    }

    // MARK: - Auto-resume while paused

    func testAutoResumeReleasesOnlyWhenTheQueueDrains() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 2
        var cfg = makeTestConfig()
        cfg.autoResume = true
        let engine = makeEngine(config: cfg, tart: tart, github: github, ssh: FakeSSH())

        await engine.setPaused(true)
        try await engine.reconcileOnce()
        var status = await engine.status()
        XCTAssertTrue(status.paused, "demand remains: the pause holds")
        XCTAssertTrue(tart.cloneCalls.isEmpty, "paused means no spawns, even with auto-resume")

        // The queue was just observed while paused: its freshness is stamped.
        status = await engine.status()
        XCTAssertNotNil(status.queuePolledAt, "a forge answered the demand fetch → the queue has an age")

        // The queue drains → the very next pass unpauses.
        github.queueDepth = 0
        try await engine.reconcileOnce()
        status = await engine.status()
        XCTAssertFalse(status.paused, "empty queue releases the fleet")
    }

    func testAutoResumeNeverReleasesOnAForgeOutage() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.failQueue = true
        var cfg = makeTestConfig()
        cfg.autoResume = true
        let engine = makeEngine(config: cfg, tart: tart, github: github, ssh: FakeSSH())

        await engine.setPaused(true)
        try await engine.reconcileOnce()
        let status = await engine.status()
        XCTAssertTrue(status.paused, "a failed queue fetch must not read as an empty queue")
        XCTAssertTrue(tart.cloneCalls.isEmpty)
        XCTAssertNil(status.queuePolledAt, "no forge answered → the queue has no fresh observation to date")
    }

    /// A forge outage is not an empty queue: idle instances must survive it,
    /// and recover to the normal scale-down once the forge answers again.
    func testScaleDownIsHeldWhileAForgeQueueIsUnreadable() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.failQueue = true
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())
        for name in ["kinhin-idle1", "kinhin-idle2"] {
            var record = VMRecord(id: name, phase: .ready)
            record.runtimeID = .tart
            engine.store.upsert(record)
            tart.vms[name] = TartVM(name: name, source: "base", status: "running")
        }

        try await engine.reconcileOnce()
        XCTAssertTrue(tart.deleteCalls.isEmpty, "idle VMs must survive a forge outage")

        github.failQueue = false
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { tart.deleteCalls.count == 2 }
    }

    /// The plan reads phases the exit watch set from a cached runner list, so a runner that just took the job (which
    /// is what emptied the queue) can still read `.ready`. Scale-down must ask the forge first and keep a busy one;
    /// it deleted it mid-job on Gitea 1.26 with no floor (e2e: longJobSurvivesTheIdleGrace).
    func testScaleDownKeepsAReadyInstanceWhoseRunnerIsBusy() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())
        for (name, busy) in [("kinhin-working", true), ("kinhin-idle", false)] {
            var record = VMRecord(id: name, phase: .ready)
            record.runtimeID = .tart
            record.platform = "github"
            engine.store.upsert(record)
            tart.vms[name] = TartVM(name: name, source: "base", status: "running")
            github.register(name: name, busy: busy)
        }

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { tart.deleteCalls.count == 1 }
        XCTAssertEqual(tart.deleteCalls, ["kinhin-idle"], "only the idle instance may go")
        XCTAssertEqual(engine.store.all.first { $0.id == "kinhin-working" }?.phase, .busy)
    }

    /// A runner list that cannot be read is not proof of idleness: the scale-down waits.
    func testScaleDownIsHeldWhileTheRunnerListIsUnreadable() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())
        var record = VMRecord(id: "kinhin-unknown", phase: .ready)
        record.runtimeID = .tart
        record.platform = "github"
        engine.store.upsert(record)
        tart.vms["kinhin-unknown"] = TartVM(name: "kinhin-unknown", source: "base", status: "running")
        github.failRunnerList = true

        try await engine.reconcileOnce()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(tart.deleteCalls.isEmpty, "an unreadable runner list must not read as idle")
    }

    /// A failed `tart delete` must not make the engine forget the VM: the
    /// record stays (`.deleting`) and the next pass retries until it is gone.
    func testFailedTeardownKeepsTheRecordAndRetries() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())
        var record = VMRecord(id: "kinhin-stuck", phase: .ready)
        record.runtimeID = .tart
        engine.store.upsert(record)
        tart.vms["kinhin-stuck"] = TartVM(name: "kinhin-stuck", source: "base", status: "running")
        tart.failNext("delete", stderr: "disk busy")

        await engine.deleteVMRecord(id: "kinhin-stuck", reason: "test")
        let stuck = engine.store.all.first { $0.id == "kinhin-stuck" }
        XCTAssertEqual(stuck?.phase, .deleting, "a failed delete keeps the record")
        XCTAssertTrue(stuck?.error?.contains("disk busy") ?? false)

        try await engine.reconcileOnce()
        await engine.settleDeletes()  // the retry runs in the background
        XCTAssertNil(engine.store.all.first { $0.id == "kinhin-stuck" }, "the retry removes it")
    }

    func testPauseWithoutAutoResumeStillSkipsQueuePolling() async throws {
        let github = FakeGitHub()
        github.queueDepth = 3
        let engine = makeEngine(tart: FakeTart(), github: github, ssh: FakeSSH())

        await engine.setPaused(true)
        try await engine.reconcileOnce()
        let status = await engine.status()
        XCTAssertTrue(status.paused)
        XCTAssertTrue(github.queuedJobsCallCount == 0, "no auto-resume: the forge is not polled")
    }

    func testStatusCarriesAutoResumePolicy() async throws {
        let engine = makeEngine(tart: FakeTart(), github: FakeGitHub(), ssh: FakeSSH())
        let status = await engine.status()
        XCTAssertEqual(status.autoResume, false, "the flag rides the status snapshot (off by default)")
        XCTAssertEqual(status.pollInterval, 5, "the cadence rides along for the countdown hint (test config: 5s)")
    }

    func testFailedVMIsCleanedUpOnNextPass() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        ssh.failWith = "injected registration failure"
        let engine = makeEngine(tart: tart, github: github, ssh: ssh)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first(where: { $0.phase == .failed }) != nil
        }
        let failedID = await engine.status().records.first!.id

        // Next pass with demand gone: the failed VM is reaped.
        ssh.failWith = nil
        github.queueDepth = 0
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.isEmpty
        }
        let deletes = tart.deleteCalls
        XCTAssertTrue(deletes.contains(failedID), "failed VM is deleted, got \(deletes)")
    }

    func testManualDeleteRemovesVMAndGitHubRegistration() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 1
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first?.phase == .ready
        }
        let id = await engine.status().records.first!.id
        github.register(name: id, busy: false)

        try await engine.deleteVM(id: id)

        let status = await engine.status()
        XCTAssertTrue(status.records.isEmpty)
        XCTAssertTrue(tart.deleteCalls.contains(id))
        XCTAssertFalse(github.deletedRunnerIDs.isEmpty, "lingering GitHub registration is removed")
    }

    func testNonEphemeralVMStaysAfterJobAndIsRemovedOnStop() async throws {
        var cfg = makeTestConfig()
        cfg.vm.ephemeral = false
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 1
        let engine = makeEngine(config: cfg, tart: tart, github: github, ssh: FakeSSH())

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.first?.phase == .ready
        }
        let id = await engine.status().records.first!.id
        github.register(name: id, busy: true)
        // A non-ephemeral runner's busy state is not watched by the engine
        // (that observation is part of the ephemeral flow); poll directly.
        try await waitUntil(timeout: 10) {
            let runners = try? await github.listRunners()
            return runners?.first { $0.name == id }?.busy == true
        }

        // Long-lived runner: the VM must survive job completion. Nothing is
        // watching it (that is the assertion), so a few ephemeral-watch
        // intervals of quiet is enough.
        try await Task.sleep(for: .milliseconds(300))
        let still = await engine.status().records.first { $0.id == id }
        XCTAssertEqual(still?.phase, .ready, "non-ephemeral VM persists beyond job completion")

        // Engine stop tears active VMs down.
        await engine.stop()
        try await waitUntil(timeout: 15) {
            let s = await engine.status()
            return s.records.isEmpty
        }
    }

    func testScaleDownDeletesIdleSurplus() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 2
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 20) {
            let s = await engine.status()
            return s.records.filter { $0.phase == .ready }.count == 2
        }

        github.queueDepth = 0
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let s = await engine.status()
            return s.records.isEmpty
        }
        XCTAssertEqual(tart.deleteCalls.count, 2, "both idle VMs were scaled away")
    }

    func testRegistrationTokenCachedAcrossConcurrentSpawns() async throws {
        let github = FakeGitHub()
        github.queueDepth = 2
        let engine = makeEngine(tart: FakeTart(), github: github, ssh: FakeSSH())

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 20) {
            let s = await engine.status()
            return s.records.filter { $0.phase == .ready }.count == 2
        }
        XCTAssertEqual(github.registrationTokenCalls, 1, "one registration token serves the whole scale-up burst")
    }
}
