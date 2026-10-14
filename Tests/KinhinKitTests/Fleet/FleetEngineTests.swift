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
            dependencies: .init(tokenLoader: { _, _ in "test-token" }, exitWatchInterval: .milliseconds(20))
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

    // MARK: - Scale-set attach path

    func testScaleSetAccountBuildsScaleSetForge() async throws {
        var cfg = makeTestConfig()
        cfg.accounts.append(makeScaleSetAccount())
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = FleetEngine(
            config: cfg, github: github, tart: tart,
            store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            dependencies: .init(
                tokenLoader: { _, _ in "test-token" },
                exitWatchInterval: .milliseconds(20)))
        await engine.attach(account: cfg.accounts.last!, token: "token", verify: false)
        let attached = engine.forgeState.withLock { $0.byPlatform["scale"] }
        XCTAssertNotNil(attached, "scale-set account should attach")
        XCTAssertTrue(attached is GitHubScaleSetForge, "should be a scale-set forge")
        let forge = attached as? GitHubScaleSetForge
        XCTAssertEqual(forge?.labels, ["kinhin"])
        XCTAssertEqual(forge?.account, "scale")
        XCTAssertNotNil(engine.forgeState.withLock { $0.scaleSetListeners["scale"] })
    }

    func testScaleSetAccountOverridesGlobalLabels() async {
        var cfg = makeTestConfig()
        cfg.accounts.append(
            AccountConfig(
                name: "scale", forge: .github, scope: "acme/widgets", labels: ["pool-label"],
                scaleSet: .init(name: "kinhin")))
        let engine = makeEngine(tart: FakeTart(), github: FakeGitHub(), ssh: FakeSSH())
        _ = await engine.attach(account: cfg.accounts.last!, token: "token", verify: false)
        let forge = engine.forgeState.withLock { $0.byPlatform["scale"] as? GitHubScaleSetForge }
        XCTAssertEqual(forge?.labels, ["pool-label"])
    }

    private func planEngine(
        container: Bool = true, docker: Bool = false, images: [KinhinConfig.ImageConfig] = []
    ) -> FleetEngine {
        var cfg = makeTestConfig()
        cfg.labels = ["self-hosted", "arm64"]
        if container { cfg.container = .init(image: "c", cpus: 1, memoryGB: 4, labels: ["kinhin-container"]) }
        if docker { cfg.docker = .init(image: "d", cpus: 1, memoryGB: 2) }
        cfg.images = images
        cfg.runtimes = .init(defaultRuntime: .appleContainer, budget: [:], routes: [])
        return FleetEngine(
            config: cfg, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost, dependencies: .init(tokenLoader: { _, _ in "t" }, exitWatchInterval: .milliseconds(20)))
    }

    /// GitHub keeps only a scale set's name, so each pool and each named
    /// image gets a set a workflow can reach with `runs-on: <name>`.
    func testScaleSetPlanNamesOneSetPerPoolAndImage() {
        let engine = planEngine(docker: true, images: [.init(name: "xcode", labels: ["xcode"])])
        let account = AccountConfig(name: "s", forge: .github, scope: "acme", scaleSet: .init(name: "kinhin"))
        let plan = engine.scaleSetPlan(account: account, baseName: "kinhin")
        XCTAssertEqual(plan.map(\.name), ["kinhin", "kinhin-container", "kinhin-docker", "kinhin-xcode"])
        XCTAssertEqual(plan.map(\.runtime), [.tart, .appleContainer, .docker, .tart])
        XCTAssertTrue(plan[1].labels.contains("kinhin-container"))
        XCTAssertTrue(plan[3].labels.contains("xcode"), "an image set carries the image's labels")
    }

    func testSinglePoolFleetKeepsJustTheBaseName() {
        let engine = planEngine(container: false)
        let account = AccountConfig(name: "s", forge: .github, scope: "acme", scaleSet: .init(name: "kinhin"))
        XCTAssertEqual(engine.scaleSetPlan(account: account, baseName: "kinhin").map(\.name), ["kinhin"])
    }

    func testClassicGitHubAccountStillBuildsGitHubForge() async throws {
        var cfg = makeTestConfig()
        cfg.accounts.append(
            AccountConfig(name: "extra", forge: .github, scope: "acme/widgets", labels: ["kinhin"]))
        let tart = FakeTart()
        let github = FakeGitHub()
        let engine = FleetEngine(
            config: cfg, github: github, tart: tart,
            store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            dependencies: .init(
                tokenLoader: { _, _ in "test-token" },
                exitWatchInterval: .milliseconds(20)))
        await engine.attach(account: cfg.accounts.last!, token: "token", verify: false)
        let attached = engine.forgeState.withLock { $0.byPlatform["extra"] }
        XCTAssertTrue(attached is GitHubForge, "classic github should stay classic")
        XCTAssertNil(engine.forgeState.withLock { $0.scaleSetListeners["extra"] })
    }

    func testScaleSetForgeDelegatesRunnersToListClient() async throws {
        var cfg = makeTestConfig()
        cfg.accounts.append(makeScaleSetAccount())
        let fake = FakeGitHub()
        fake.register(name: "runner-one", busy: false)
        let engine = FleetEngine(
            config: cfg, github: fake, tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            dependencies: .init(
                tokenLoader: { _, _ in "test-token" },
                exitWatchInterval: .milliseconds(20)))
        await engine.attach(account: cfg.accounts.last!, token: "token", verify: false)
        let forge = engine.forgeState.withLock { $0.byPlatform["scale"] } as? GitHubScaleSetForge
        let runners = try await forge?.runners()
        XCTAssertEqual(runners?.count, 1)
        XCTAssertEqual(runners?.first?.name, "runner-one")
        XCTAssertFalse(runners?.first?.busy ?? true)
    }

    func testScaleSetForgeExposesJitRegistrationTokens() async throws {
        let listener = makeTestListener()
        let forge = GitHubScaleSetForge(
            account: makeScaleSetAccount(), token: "token", client: FakeGitHub(), listener: listener)
        let jit = try await forge.jitRunnerTokens(names: ["vm"], labels: [])
        XCTAssertEqual(jit, ["vm": "jit-vm"])
    }

    func testScaleSetForgeRejectsSharedTokenRegistration() async throws {
        var cfg = makeTestConfig()
        cfg.accounts.append(makeScaleSetAccount())
        let fake = FakeGitHub()
        let engine = FleetEngine(
            config: cfg, github: fake, tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            dependencies: .init(
                tokenLoader: { _, _ in "test-token" },
                exitWatchInterval: .milliseconds(20)))
        await engine.attach(account: cfg.accounts.last!, token: "token", verify: false)
        let forge = engine.forgeState.withLock { $0.byPlatform["scale"] } as? GitHubScaleSetForge
        do {
            _ = try await forge?.mintRegistrationToken()
            XCTFail("scale-set registration must throw")
        } catch EngineError.scaleSetRegistrationUnsupported {
        } catch {
            XCTFail("expected EngineError.scaleSetRegistrationUnsupported, got \(error)")
        }
    }

    func testScaleSetListenerSnapshotIsEmptyBeforeStart() async throws {
        let listener = makeTestListener()
        let snap = await listener.snapshot()
        XCTAssertNil(snap)
        let empty = try await listener.queuedJobs()
        XCTAssertTrue(empty.isEmpty)
        // snapshot() is actor-isolated; assert it through await.
        let snap2 = await listener.snapshot()
        XCTAssertNil(snap2)
    }

    func testScaleSetListenerSnapshotDerivesJobsFromTrackedEvents() async throws {
        let listener = makeTestListener()
        let event = GitHubScaleSetJobEvent(
            ownerName: "acme", repositoryName: "widgets",
            jobDisplayName: "build", requestLabels: ["macos"], runnerRequestId: "r-1",
            eventType: .jobAssigned)
        await listener.updateSnapshot(
            statistics: .init(totalAssignedJobs: 1, activeNodesCount: 0), pendingActions: ["m-1": event])
        let snap = await listener.snapshot()
        XCTAssertEqual(snap?.statistics.totalAssignedJobs, 1)
        XCTAssertEqual(snap?.trackedJobs.count, 1)
        XCTAssertEqual(snap?.attributedRepos, ["acme/widgets"])
        let jobs = try await listener.queuedJobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.name, "build")
        XCTAssertEqual(jobs.first?.repository, "acme/widgets")
        XCTAssertEqual(jobs.first?.labels, ["macos"])
        let snap2 = await listener.snapshot()
        XCTAssertEqual(snap2?.statistics.totalAssignedJobs, 1)
    }

    func testScaleSetListenerSynthesizesPlaceholdersWhenTrackedBelowStatistics() async throws {
        let listener = makeTestListener()
        await listener.updateSnapshot(
            statistics: .init(totalAssignedJobs: 3, activeNodesCount: 0),
            pendingActions: [:]
        )
        // No attributed repos yet (an org-scoped listener after a restart): the demand still counts,
        // as placeholders without a repository.
        let jobs = try await listener.queuedJobs()
        XCTAssertEqual(jobs.count, 3, "reported demand must not vanish just because no repo is attributed")
        XCTAssertTrue(jobs.allSatisfy { $0.name.hasPrefix("scale-set placeholder") && $0.repository == nil })

        let event = GitHubScaleSetJobEvent(
            ownerName: "acme", repositoryName: "widgets",
            jobDisplayName: "build", requestLabels: [], runnerRequestId: "r-1",
            eventType: .jobAssigned)
        await listener.updateSnapshot(
            statistics: .init(totalAssignedJobs: 3, activeNodesCount: 0),
            pendingActions: ["m-1": event]
        )
        let jobs2 = try await listener.queuedJobs()
        XCTAssertEqual(jobs2.count, 3, "tracked 1 vs statistics 3 should yield 1 real + 2 placeholders")
        XCTAssertEqual(jobs2.first?.name, "build")
        let placeholders = jobs2.filter { $0.name.hasPrefix("scale-set placeholder") }
        XCTAssertEqual(placeholders.count, 2)
        XCTAssertEqual(placeholders.map { $0.repository }, ["acme/widgets", "acme/widgets"])
        let snap = await listener.snapshot()
        XCTAssertEqual(snap?.trackedJobs.count, 1)
    }

    func testScaleSetListenerAppliesJobEventsAndAcknowledgesMessage() async throws {
        let client = RecordingScaleSetClient()
        let listener = GitHubScaleSetListener(
            client: client, scaleSetIdSupplier: { 17 }, ownerName: "acme", fallbackRepository: "acme/widgets")
        let event = GitHubScaleSetJobEvent(
            ownerName: "acme", repositoryName: "widgets", jobDisplayName: "build", requestLabels: [],
            runnerRequestId: "17", eventType: .jobAvailable)
        let message = GitHubScaleSetMessage(
            messageId: "9", statistics: .init(totalAssignedJobs: 1, activeNodesCount: 0), events: [event])
        try await listener.process([message], session: makeSession(), scaleSetId: 17)
        let firstAcknowledgements = await client.acknowledged
        XCTAssertEqual(firstAcknowledgements, ["9"])
        let acquired = await client.acquired
        XCTAssertEqual(acquired, [[17]], "a JobAvailable job is acquired, or GitHub never assigns it")
        let assignedJobs = try await listener.queuedJobs()
        XCTAssertEqual(assignedJobs.first?.name, "build")

        let completed = GitHubScaleSetMessage(
            messageId: "10", statistics: .init(totalAssignedJobs: 0, activeNodesCount: 0),
            events: [
                GitHubScaleSetJobEvent(
                    ownerName: "acme", repositoryName: "widgets", jobDisplayName: "build", requestLabels: [],
                    runnerRequestId: "17", eventType: .jobCompleted)
            ])
        try await listener.process([completed], session: makeSession(), scaleSetId: 17)
        let allAcknowledgements = await client.acknowledged
        XCTAssertEqual(allAcknowledgements, ["9", "10"])
        let acquiredAfterCompletion = await client.acquired
        XCTAssertEqual(acquiredAfterCompletion, [[17]], "only JobAvailable events are acquired")
        let remainingJobs = try await listener.queuedJobs()
        XCTAssertTrue(remainingJobs.isEmpty)
    }

    /// actions/scaleset's contract: acquire before the ack, so a failed acquire leaves the
    /// message unacknowledged and GitHub redelivers it.
    func testAFailedAcquireLeavesTheMessageUnacknowledged() async throws {
        let client = RecordingScaleSetClient()
        await client.setFailAcquire(true)
        let listener = GitHubScaleSetListener(
            client: client, scaleSetIdSupplier: { 17 }, ownerName: "acme", fallbackRepository: "acme/widgets")
        let message = GitHubScaleSetMessage(
            messageId: "9", statistics: .init(totalAssignedJobs: 1, activeNodesCount: 0),
            events: [
                GitHubScaleSetJobEvent(
                    ownerName: "acme", repositoryName: "widgets", jobDisplayName: "build", requestLabels: [],
                    runnerRequestId: "17", eventType: .jobAvailable)
            ])
        do {
            try await listener.process([message], session: makeSession(), scaleSetId: 17)
            XCTFail("the acquire failure must surface")
        } catch {}
        let acknowledged = await client.acknowledged
        XCTAssertEqual(acknowledged, [])
    }

    /// The acquire POST succeeded but its reply could not be read: the acquisition
    /// stands, so the message is still acknowledged instead of failing the session.
    func testAnUnreadableAcquireReplyStillAcknowledgesTheMessage() async throws {
        let client = RecordingScaleSetClient()
        await client.setUnreadableAcquireReply(true)
        let listener = GitHubScaleSetListener(
            client: client, scaleSetIdSupplier: { 17 }, ownerName: "acme", fallbackRepository: "acme/widgets")
        let message = GitHubScaleSetMessage(
            messageId: "9", statistics: .init(totalAssignedJobs: 1, activeNodesCount: 0),
            events: [
                GitHubScaleSetJobEvent(
                    ownerName: "acme", repositoryName: "widgets", jobDisplayName: "build", requestLabels: [],
                    runnerRequestId: "17", eventType: .jobAvailable)
            ])
        try await listener.process([message], session: makeSession(), scaleSetId: 17)
        let acknowledged = await client.acknowledged
        let acquired = await client.acquired
        XCTAssertEqual(acknowledged, ["9"])
        XCTAssertEqual(acquired, [[17]])
    }

    func testScaleSetListenerReplacesDuplicateMessageWithLatestEvent() async throws {
        let listener = makeTestListener()
        let first = GitHubScaleSetJobEvent(
            ownerName: "acme", repositoryName: "widgets",
            jobDisplayName: "first", requestLabels: [], runnerRequestId: "r-1",
            eventType: .jobAvailable)
        let second = GitHubScaleSetJobEvent(
            ownerName: "acme", repositoryName: "widgets",
            jobDisplayName: "second", requestLabels: [], runnerRequestId: "r-1",
            eventType: .jobAssigned)
        await listener.updateSnapshot(
            statistics: .init(totalAssignedJobs: 1, activeNodesCount: 0), pendingActions: ["m-1": first])
        let before = try await listener.queuedJobs()
        XCTAssertEqual(before.first?.name, "first")
        await listener.updateSnapshot(
            statistics: .init(totalAssignedJobs: 1, activeNodesCount: 0), pendingActions: ["m-1": second])
        let after = try await listener.queuedJobs()
        XCTAssertEqual(after.first?.name, "second")
        let snap = await listener.snapshot()
        XCTAssertEqual(snap?.trackedJobs.first?.jobDisplayName, "second")
    }

    func testScaleSetListenerReturnsCachedScaleSetId() async throws {
        let listener = makeTestListener()
        let id = try await listener.currentScaleSetId()
        XCTAssertEqual(id, 17)
        let snap = await listener.snapshot()
        XCTAssertNil(snap)
    }

    func testScaleSetListenerLoadsLiveStatisticsForDemand() async throws {
        let listener = makeTestListener()
        let statistics = try await listener.scaleSetStatistics()
        XCTAssertEqual(statistics.totalAssignedJobs, 2)
        XCTAssertEqual(statistics.activeNodesCount, 1)
    }

    func testScaleSetForgeUsesCachedListenerStatistics() async throws {
        let listener = makeTestListener()
        let forge = GitHubScaleSetForge(
            account: makeScaleSetAccount(), token: "token", client: FakeGitHub(), listener: listener)
        let statistics = try await forge.scaleSetStatistics()
        XCTAssertEqual(statistics.totalAssignedJobs, 2)
    }

    func testScaleSetJitBootstrapUsesJitConfigWithoutSharedTokenFlags() {
        let script = RunnerBootstrap.jitRegistrationScript(encodedJitConfig: "secret'$(bad)", name: "vm")
        XCTAssertTrue(script.contains("--jitconfig 'secret'\\''$(bad)'"))
        XCTAssertFalse(script.contains("--token"))
        XCTAssertFalse(script.contains("--labels"))
        XCTAssertFalse(script.contains("--url"))
    }

    /// JIT runners start through `run.sh --jitconfig` (config.sh has no such option),
    /// keep their output, and fail registration at once if the runner dies.
    func testJitBootstrapStartsRunShAndChecksTheRunnerStayedUp() {
        for script in [
            RunnerBootstrap.jitRegistrationScript(encodedJitConfig: "abc", name: "vm"),
            RunnerBootstrap.linuxJitRegistrationScript(encodedJitConfig: "abc", name: "vm"),
        ] {
            XCTAssertTrue(script.contains("./run.sh --jitconfig 'abc'"), script)
            XCTAssertFalse(script.contains("./config.sh --"), "JIT runners are already registered by the API")
            XCTAssertTrue(script.contains("> run.log 2>&1 &"), "the runner's output must be kept for diagnosis")
            XCTAssertTrue(script.contains("kill -0 \"$runner_pid\""), script)
            XCTAssertTrue(script.contains("tail -n 20 run.log"), script)
        }
    }

    func testScaleSetListenerClearsStateOnStop() async throws {
        let listener = makeTestListener()
        let event = GitHubScaleSetJobEvent(
            ownerName: "acme", repositoryName: "widgets",
            jobDisplayName: "build", requestLabels: [], runnerRequestId: "r-1",
            eventType: .jobAssigned)
        await listener.updateSnapshot(
            statistics: .init(totalAssignedJobs: 1, activeNodesCount: 0), pendingActions: ["m-1": event])
        let before = try await listener.queuedJobs()
        XCTAssertFalse(before.isEmpty)
        await listener.stop()
        let after = try await listener.queuedJobs()
        XCTAssertTrue(after.isEmpty)
        let snap = await listener.snapshot()
        XCTAssertNil(snap)
        let snap2 = await listener.snapshot()
        XCTAssertNil(snap2)
    }

    // MARK: - Helpers

    func makeSession() -> GitHubScaleSetSession {
        GitHubScaleSetSession(
            sessionId: "s-test", messageQueueUrl: URL(string: "https://example.invalid/msgs")!,
            messageQueueAccessToken: "mq-token")
    }

    func makeTestListener(runners: [GitHubActionsRunner] = []) -> GitHubScaleSetListener {
        let client = StubScaleSetClient(runners: runners)
        return GitHubScaleSetListener(
            client: client,
            scaleSetIdSupplier: { 17 },
            ownerName: "acme",
            pollInterval: .seconds(99)
        )
    }

    func makeScaleSetAccount(name: String = "scale", labels: [String] = ["kinhin"], scaleSetName: String = "kinhin")
        -> AccountConfig
    {
        AccountConfig(
            name: name, forge: .github, scope: "acme/widgets",
            labels: labels, scaleSet: .init(name: scaleSetName))
    }

    /// Minimal scale-set client double for listener tests; the lifecycle paths
    /// that need HTTP behavior get explicit deterministic responses.
    private final class StubScaleSetClient: GitHubScaleSetServing, Sendable {
        private let runners: [GitHubActionsRunner]
        init(runners: [GitHubActionsRunner] = []) {
            self.runners = runners
        }

        func exchangeRegistrationToken(registrationToken: String) async throws -> GitHubScaleSetRegistrationToken {
            GitHubScaleSetRegistrationToken(
                token: "admin-jwt", expiresAt: .now + 3600, actionsUrl: URL(string: "https://example.invalid")!)
        }

        func ensureScaleSet(name: String, labels: [String], runnerGroup: String?) async throws -> GitHubScaleSet {
            GitHubScaleSet(id: 17, name: name, runnerGroupName: runnerGroup ?? "default", labels: labels)
        }

        func patchScaleSet(id: Int, labels: [String]) async throws {
        }

        func createSession(scaleSetId: Int, ownerName: String) async throws -> GitHubScaleSetSession {
            GitHubScaleSetSession(
                sessionId: "s-1",
                messageQueueUrl: URL(string: "https://example.invalid/msgs")!,
                messageQueueAccessToken: "mq-token"
            )
        }

        func refreshSession(scaleSetId: Int, sessionId: String) async throws -> GitHubScaleSetSession {
            GitHubScaleSetSession(
                sessionId: sessionId, messageQueueUrl: URL(string: "https://example.invalid/msgs")!,
                messageQueueAccessToken: "mq-token")
        }

        func deleteSession(scaleSetId: Int, sessionId: String) async throws {
        }

        func pollMessages(session: GitHubScaleSetSession, lastMessageId: String?, maxCapacity: Int) async throws
            -> [GitHubScaleSetMessage]
        {
            []
        }

        func ackMessage(session: GitHubScaleSetSession, messageId: String) async throws {
        }
        func acquireJobs(session: GitHubScaleSetSession, scaleSetId: Int, requestIds: [Int64]) async throws -> [Int64] {
            requestIds
        }

        func generateJitConfig(scaleSetId: Int, name: String, workFolder: String) async throws
            -> GitHubScaleSetJitConfig
        {
            GitHubScaleSetJitConfig(encodedJitConfig: "jit-\(name)")
        }

        func scaleSetStatistics(scaleSetId: Int) async throws -> GitHubScaleSetStatistics {
            GitHubScaleSetStatistics(totalAssignedJobs: 2, activeNodesCount: 1)
        }

        func runnerByName(name: String) async throws -> GitHubActionsRunner? {
            runners.first(where: { $0.name == name })
        }
    }

    private actor RecordingScaleSetClient: GitHubScaleSetServing {
        private(set) var acknowledged: [String] = []
        private(set) var acquired: [[Int64]] = []
        var failAcquire = false
        var unreadableAcquireReply = false

        func setFailAcquire(_ value: Bool) { failAcquire = value }
        func setUnreadableAcquireReply(_ value: Bool) { unreadableAcquireReply = value }
        func acquireJobs(session: GitHubScaleSetSession, scaleSetId: Int, requestIds: [Int64]) async throws -> [Int64] {
            if failAcquire { throw GitHubError.http(503, "unavailable") }
            if unreadableAcquireReply {
                acquired.append(requestIds)
                throw GitHubError.decoding("acquirejobs response: garbled")
            }
            acquired.append(requestIds)
            return requestIds
        }

        func exchangeRegistrationToken(registrationToken: String) async throws -> GitHubScaleSetRegistrationToken {
            GitHubScaleSetRegistrationToken(
                token: "jwt", expiresAt: .now + 3600, actionsUrl: URL(string: "https://actions.invalid")!)
        }

        func ensureScaleSet(name: String, labels: [String], runnerGroup: String?) async throws -> GitHubScaleSet {
            GitHubScaleSet(id: 17, name: name, runnerGroupName: runnerGroup ?? "default", labels: labels)
        }

        func patchScaleSet(id: Int, labels: [String]) async throws {}
        func createSession(scaleSetId: Int, ownerName: String) async throws -> GitHubScaleSetSession { fatalError() }
        func refreshSession(scaleSetId: Int, sessionId: String) async throws -> GitHubScaleSetSession { fatalError() }
        func deleteSession(scaleSetId: Int, sessionId: String) async throws {}
        func pollMessages(session: GitHubScaleSetSession, lastMessageId: String?, maxCapacity: Int) async throws
            -> [GitHubScaleSetMessage]
        { [] }
        func ackMessage(session: GitHubScaleSetSession, messageId: String) async throws {
            acknowledged.append(messageId)
        }
        func generateJitConfig(scaleSetId: Int, name: String, workFolder: String) async throws
            -> GitHubScaleSetJitConfig
        {
            GitHubScaleSetJitConfig(encodedJitConfig: "jit-\(name)")
        }
        func scaleSetStatistics(scaleSetId: Int) async throws -> GitHubScaleSetStatistics {
            GitHubScaleSetStatistics(totalAssignedJobs: 0, activeNodesCount: 0)
        }
    }
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
    func cancelWorkflowRun(ids: [Int]) async throws -> Bool { true }
    func skipWorkflowRun(ids: [Int]) async throws -> Bool { true }
}
