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
            host: testHost,
            dependencies: .init(exitWatchInterval: .milliseconds(20))
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
        // A pass has run once it has stamped the queue poll.
        try await waitUntil(timeout: 10) { await engine.status().queuePolledAt != nil }
        await engine.stop()

        let status = await engine.status()
        XCTAssertEqual(status.desired, 0)
        XCTAssertTrue(tart.cloneCalls.isEmpty)
    }

    func testStartWarnsOnceWhenBaseImageIsNotDigestPinned() async throws {
        var cfg = makeTestConfig()
        cfg.baseImage = "ghcr.io/cirruslabs/ubuntu:latest"  // mutable: must warn
        let engine = makeEngine(config: cfg, tart: FakeTart(), github: FakeGitHub(), ssh: FakeSSH())

        await engine.start()
        await engine.stop()

        let snapshot = Log.snapshot(limit: 100)
        let warnings = snapshot.filter {
            $0.level == "warn" && $0.component == "engine" && $0.message.contains("tag is mutable")
        }
        XCTAssertEqual(warnings.count, 1, "exactly one drift warning per start: \(warnings.map(\.message))")
        XCTAssertTrue(warnings.first?.message.contains("kinhin image digest") ?? false, warnings.first?.message ?? "")
    }

    func testStartDoesNotWarnForPinnedOrAbsentBaseImage() async throws {
        // Pinned: silent.
        var pinned = makeTestConfig()
        pinned.baseImage = "ghcr.io/cirruslabs/ubuntu:latest@sha256:\(String(repeating: "ab", count: 32))"
        let pinnedEngine = makeEngine(config: pinned, tart: FakeTart(), github: FakeGitHub(), ssh: FakeSSH())
        await pinnedEngine.start()
        await pinnedEngine.stop()
        let pinnedSnapshot = Log.snapshot(limit: 100)
        XCTAssertFalse(
            pinnedSnapshot.contains { $0.level == "warn" && $0.message.contains("tag is mutable") },
            "a digest-pinned base_image must not warn")

        // Absent (the default): silent too.
        let defaultEngine = makeEngine(tart: FakeTart(), github: FakeGitHub(), ssh: FakeSSH())
        await defaultEngine.start()
        await defaultEngine.stop()
        XCTAssertFalse(
            Log.snapshot(limit: 100).contains { $0.level == "warn" && $0.message.contains("tag is mutable") },
            "no base_image key means nothing to nag about")
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

    // MARK: - Many-to-one (runners_per_vm)

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

    /// An exit watcher deleting its own VM runs inside the lifecycle task:
    /// deleteVMRecord must not cancel that task, or the runner cleanup that
    /// follows fails on cancellation (and is swallowed) — leaving dead
    /// registrations behind on forges whose runners never deregister.
    func testLifecycleDeletingItsOwnVMStillSweepsRunners() async throws {
        let tart = FakeTart()
        let fake = FakeGitHub()
        let engine = makeEngine(tart: tart, github: fake, ssh: FakeSSH())
        let github = CancellationCheckingGitHub(fake)
        engine.forgeState.withLock { state in
            state.byPlatform["github"] = GitHubForge(
                credentials: .github(token: "t", scope: "acme/widgets"), labels: ["kinhin"], client: github,
                account: "github")
        }
        let vm = "kinhin-self-delete"
        var record = VMRecord(id: vm, phase: .busy)
        record.platform = "github"
        engine.store.upsert(record)
        fake.register(name: vm, busy: false)

        engine.spawnLifecycleTask(id: vm) {
            await engine.deleteVMRecord(id: vm, reason: "jobs finished")
        }
        try await waitUntil(timeout: 10) { !engine.store.all.contains { $0.id == vm } }
        XCTAssertEqual(fake.deletedRunnerIDs.count, 1, "the lifecycle's own delete must deregister its runner")
    }

    // MARK: - Helpers

}

/// Forwards to a FakeGitHub but fails on a cancelled task, the way the live
/// URLSession client does.
private final class CancellationCheckingGitHub: GitHubServing, Sendable {
    let base: FakeGitHub
    init(_ base: FakeGitHub) { self.base = base }
    var configureURL: String { base.configureURL }
    func fetchRegistrationToken() async throws -> RegistrationToken {
        try Task.checkCancellation()
        return try await base.fetchRegistrationToken()
    }
    func listRunners() async throws -> [GHRunner] {
        try Task.checkCancellation()
        return try await base.listRunners()
    }
    func deleteRunner(id: Int) async throws {
        try Task.checkCancellation()
        try await base.deleteRunner(id: id)
    }
    func queuedJobs(matching labels: Set<String>) async throws -> [QueuedJob] {
        try await base.queuedJobs(matching: labels)
    }
    func runningJobs(matching labels: Set<String>) async throws -> [RunningJob] {
        try await base.runningJobs(matching: labels)
    }
}
