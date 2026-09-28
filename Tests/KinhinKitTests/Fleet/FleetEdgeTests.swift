import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class FleetEdgeTests: XCTestCase {
    func makeEngine(config: KinhinConfig? = nil, tart: FakeTart, github: FakeGitHub, ssh: FakeSSH) -> FleetEngine {
        FleetEngine(
            config: config ?? makeTestConfig(),
            github: github,
            tart: tart,
            store: makeTestStore(),
            ssh: ssh,
            host: testHost
        )
    }

    func waitUntil(timeout: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    // MARK: Disk-pressure guard

    func testDiskPressureHoldsSpawnsAndSurfacesLastError() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 2
        let engine = makeEngine(tart: tart, github: github, ssh: FakeSSH())
        // 15 GB free < 50 GB default VM footprint + 10 GB reserve.
        engine.hostProbe = { HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 15, arm64: true) }

        try await engine.reconcileOnce()
        let status = await engine.status()
        XCTAssertEqual(status.desired, 2, "desired is computed from the queue")
        XCTAssertTrue(tart.cloneCalls.isEmpty, "no VM may spawn under disk pressure")
        let lastError = await status.lastError ?? ""
        XCTAssertTrue(lastError.contains("disk pressure"), "\(lastError)")

        // Freeing disk lets the next pass spawn again (desired = 2 → both clone).
        engine.hostProbe = { HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true) }
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) { tart.cloneCalls.count == 2 }
    }

    func testDiskGuardCountsExplicitDiskGB() async throws {
        let tart = FakeTart()
        let github = FakeGitHub()
        github.queueDepth = 1
        var cfg = makeTestConfig()
        cfg.diskGB = 30  // explicit footprint: 30 + 10 reserve = 40 needed
        let engine = makeEngine(config: cfg, tart: tart, github: github, ssh: FakeSSH())
        engine.hostProbe = { HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 39, arm64: true) }

        try await engine.reconcileOnce()
        var status = await engine.status()
        XCTAssertTrue(status.lastError?.contains("disk pressure") ?? false)
        XCTAssertTrue(tart.cloneCalls.isEmpty)

        // 41 GB free clears 40 needed.
        engine.hostProbe = { HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 41, arm64: true) }
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
        var status = await engine.status()
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

    // MARK: Auto-resume while paused

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

        await engine.deleteVM(id: id)

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

        // Long-lived runner: the VM must survive job completion.
        try await Task.sleep(nanoseconds: 2_000_000_000)
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
