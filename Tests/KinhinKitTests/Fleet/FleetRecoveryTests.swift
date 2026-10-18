import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Recovery after a (re)start: surviving instances are attributed to the
/// runtime that actually reported them, not the engine's primary runtime.
final class FleetRecoveryTests: XCTestCase {
    private let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)

    /// A mixed fleet (Apple container primary, Tart alongside) with one
    /// surviving Tart VM.
    private func makeMixedEngine(store: FleetStore) -> (FleetEngine, FakeTart) {
        var config = makeTestConfig()
        config.container = .init(image: "kinhin-ci-linux", cpus: 2, memoryGB: 4)
        let tart = FakeTart()
        tart.vms["kinhin-t1"] = TartVM(name: "kinhin-t1", source: "tahoe-base", status: "running")
        let engine = FleetEngine(
            config: config,
            github: FakeGitHub(),
            tart: tart,
            store: store,
            ssh: FakeSSH(),
            host: host,
            containerShell: FakeShell(),
            dependencies: .init(lifecycleDrainTimeout: .milliseconds(200))
        )
        return (engine, tart)
    }

    func testAdoptedInstanceKeepsTheRuntimeThatReportedIt() async {
        let store = makeTestStore()
        let (engine, _) = makeMixedEngine(store: store)
        XCTAssertEqual(engine.runtime.id, .appleContainer, "fixture: the primary runtime is the container one")

        await engine.recoverIfNeeded()

        let adopted = store.all.first { $0.id == "kinhin-t1" }
        XCTAssertEqual(adopted?.runtimeID, .tart, "a Tart VM must not be adopted as a container")
        await engine.detachKeepingInstances()
    }

    /// A scratch VM an image bake left behind shares the fleet's prefix, but it is not a runner: recovery must not
    /// adopt it, while a real instance next to it is still recovered.
    func testRecoverySkipsAScratchVMAndAdoptsTheRealInstance() async {
        let store = makeTestStore()
        let (engine, tart) = makeMixedEngine(store: store)
        tart.vms["kinhin-prepare-tmp-1760000000"] = TartVM(
            name: "kinhin-prepare-tmp-1760000000", source: "tahoe-base", status: "stopped")

        await engine.recoverIfNeeded()

        XCTAssertNotNil(store.all.first { $0.id == "kinhin-t1" }, "the real instance is recovered")
        XCTAssertNil(store.all.first { $0.id == "kinhin-prepare-tmp-1760000000" }, "a scratch VM is never adopted")
        await engine.detachKeepingInstances()
    }

    /// A runtime that can't be listed (tart wedged, a daemon down) must not
    /// read as "every instance vanished": its records are kept, not dropped
    /// (which would orphan the running VMs).
    func testRecordsSurviveAFailedListing() async {
        let store = makeTestStore()
        var record = VMRecord(id: "kinhin-t2", phase: .busy)
        record.runtimeID = .tart
        store.upsert(record)
        let (engine, tart) = makeMixedEngine(store: store)
        tart.failList = true

        await engine.recoverIfNeeded()

        XCTAssertNotNil(store.all.first { $0.id == "kinhin-t2" }, "an unlistable runtime's record is kept")
        await engine.detachKeepingInstances()
    }

    func testLegacyRecordWithoutRuntimeIsBackfilled() async {
        let store = makeTestStore()
        store.upsert(VMRecord(id: "kinhin-t1", phase: .ready))
        let (engine, _) = makeMixedEngine(store: store)

        await engine.recoverIfNeeded()

        let record = store.all.first { $0.id == "kinhin-t1" }
        XCTAssertEqual(record?.runtimeID, .tart)
        await engine.detachKeepingInstances()
    }

    func testRecordWithRuntimeIsLeftAsIs() async {
        let store = makeTestStore()
        var record = VMRecord(id: "kinhin-t1", phase: .ready)
        record.runtimeID = .tart
        store.upsert(record)
        let (engine, _) = makeMixedEngine(store: store)

        await engine.recoverIfNeeded()

        XCTAssertEqual(store.all.map(\.id), ["kinhin-t1"])
        XCTAssertEqual(store.all.first?.runtimeID, .tart)
        await engine.detachKeepingInstances()
    }

    /// A restart (or `max_runners` edit) must not replay registration on an
    /// instance that already took a job: re-running `config.sh` would remove
    /// the runner mid-job.
    func testBusyInstanceIsNotReRegisteredOnRecovery() async throws {
        let store = makeTestStore()
        var record = VMRecord(id: "kinhin-t1", phase: .busy)
        record.runtimeID = .tart
        store.upsert(record)
        var config = makeTestConfig()
        config.vm.ephemeral = true
        let tart = FakeTart()
        tart.vms["kinhin-t1"] = TartVM(name: "kinhin-t1", source: "tahoe-base", status: "running")
        let ssh = FakeSSH()
        let engine = FleetEngine(
            config: config, github: FakeGitHub(), tart: tart, store: store, ssh: ssh, host: host,
            containerShell: FakeShell(), dependencies: .init(lifecycleDrainTimeout: .milliseconds(200)))

        await engine.recoverIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(ssh.scripts.isEmpty, "no registration script may run on a live busy instance")
        XCTAssertNotEqual(store.all.first { $0.id == "kinhin-t1" }?.phase, .cloning)
        await engine.detachKeepingInstances()
    }

    /// A corrupt fleet.json (and project-images.json) must reach the status
    /// as alerts naming the kept copy, not only the log.
    func testCorruptStateFilesRaiseStatusAlerts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }  // test temp dir
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("fleet.json"))
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("project-images.json"))
        let store = FleetStore(directory: dir)
        var dependencies = FleetEngine.Dependencies(lifecycleDrainTimeout: .milliseconds(200))
        dependencies.projectImageStore = ProjectImageStore(directory: dir)
        let engine = FleetEngine(
            config: makeTestConfig(), github: FakeGitHub(), tart: FakeTart(), store: store, ssh: FakeSSH(),
            host: host, dependencies: dependencies)

        await engine.recoverIfNeeded()

        let alerts = await engine.status().alerts ?? []
        let fleet = try XCTUnwrap(alerts.first { $0.source == "store:fleet" })
        let kept = try XCTUnwrap(store.recoveredFromCorruptFile)
        XCTAssertTrue(fleet.message.contains(kept.lastPathComponent), fleet.message)
        XCTAssertTrue(alerts.contains { $0.source == "store:project-images" })
        await engine.detachKeepingInstances()
    }

    func testCleanStateRaisesNoStoreAlert() async {
        let (engine, _) = makeMixedEngine(store: makeTestStore())
        await engine.recoverIfNeeded()
        let alerts = await engine.status().alerts ?? []
        XCTAssertFalse(alerts.contains { $0.source.hasPrefix("store:") })
        await engine.detachKeepingInstances()
    }

    // MARK: - Adoption: the forge decides whether a live VM is registered again

    /// A tart-only engine over `store` (a corrupt fleet.json leaves it empty) with `github` as its forge.
    private func makeAdoptingEngine(
        store: FleetStore, github: FakeGitHub, tart: FakeTart, ssh: FakeSSH
    ) -> FleetEngine {
        var config = makeTestConfig()
        config.vm.ephemeral = true
        return FleetEngine(
            config: config, github: github, tart: tart, store: store, ssh: ssh, host: host,
            dependencies: .init(lifecycleDrainTimeout: .milliseconds(200)))
    }

    private func runningTartVM(_ tart: FakeTart) {
        tart.vms["kinhin-t1"] = TartVM(name: "kinhin-t1", source: "tahoe-base", status: "running")
    }

    /// The store is empty but the VM is live, and its runner is busy on the forge (a job is running).
    /// Recovery must watch that runner, not register it again: registration would fail the job.
    func testRecoveredInstanceWithABusyRunnerIsWatchedNotReRegistered() async throws {
        let store = makeTestStore()
        let tart = FakeTart()
        runningTartVM(tart)
        let github = FakeGitHub()
        github.register(name: "kinhin-t1", busy: true)
        let ssh = FakeSSH()
        let engine = makeAdoptingEngine(store: store, github: github, tart: tart, ssh: ssh)

        await engine.recoverIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(ssh.scripts.isEmpty, "no registration script may run on a recovered VM whose runner is busy")
        XCTAssertEqual(store.all.first { $0.id == "kinhin-t1" }?.phase, .busy)
        await engine.detachKeepingInstances()
    }

    /// The same, with the registered runner idle: it is watched as ready, and still not registered again.
    func testRecoveredInstanceWithAnIdleRunnerIsWatchedAsReady() async throws {
        let store = makeTestStore()
        let tart = FakeTart()
        runningTartVM(tart)
        let github = FakeGitHub()
        github.register(name: "kinhin-t1", busy: false)
        let ssh = FakeSSH()
        let engine = makeAdoptingEngine(store: store, github: github, tart: tart, ssh: ssh)

        await engine.recoverIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(ssh.scripts.isEmpty, "no registration script may run on a recovered VM with a registered runner")
        XCTAssertEqual(store.all.first { $0.id == "kinhin-t1" }?.phase, .ready)
        await engine.detachKeepingInstances()
    }

    /// A forge that cannot be asked holds the VM: nothing is registered over it, the status says so, and it is
    /// released once the forge answers (here: the busy runner is found and watched).
    func testHeldInstanceIsNotRegisteredUntilTheForgeAnswers() async throws {
        let store = makeTestStore()
        let tart = FakeTart()
        runningTartVM(tart)
        let github = FakeGitHub()
        github.register(name: "kinhin-t1", busy: true)
        github.failRunnerList = true
        let ssh = FakeSSH()
        let engine = makeAdoptingEngine(store: store, github: github, tart: tart, ssh: ssh)

        await engine.recoverIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(ssh.scripts.isEmpty, "a held VM is not registered while the forge cannot be asked")
        XCTAssertEqual(store.all.first { $0.id == "kinhin-t1" }?.phase, .booting)
        let held = await engine.status().alerts ?? []
        XCTAssertTrue(held.contains { $0.source == "adoption" }, "the held VM is shown as an alert")

        github.failRunnerList = false
        await engine.settleAdoptions()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(ssh.scripts.isEmpty, "a released VM with a busy runner is watched, not registered")
        XCTAssertEqual(store.all.first { $0.id == "kinhin-t1" }?.phase, .busy)
        let released = await engine.status().alerts ?? []
        XCTAssertFalse(released.contains { $0.source == "adoption" }, "the alert clears once nothing is held")
        await engine.detachKeepingInstances()
    }

    /// Recovery asks the forge once for the whole set, not once per VM.
    func testRecoveryListsTheForgeOnceForAllInstances() async throws {
        let store = makeTestStore()
        let tart = FakeTart()
        let github = FakeGitHub()
        for n in 1...3 {
            tart.vms["kinhin-t\(n)"] = TartVM(name: "kinhin-t\(n)", source: "tahoe-base", status: "running")
            github.register(name: "kinhin-t\(n)", busy: true)
        }
        var config = makeTestConfig()
        // Classic persistent runners: nothing watches them, so no other list calls happen during recovery.
        config.vm.ephemeral = false
        let engine = FleetEngine(
            config: config, github: github, tart: tart, store: store, ssh: FakeSSH(), host: host,
            dependencies: .init(lifecycleDrainTimeout: .milliseconds(200)))

        await engine.recoverIfNeeded()

        XCTAssertEqual(github.listRunnersCallCount, 1, "one listing serves every recovered instance")
        XCTAssertEqual(store.all.first { $0.id == "kinhin-t1" }?.phase, .ready, "a classic runner is not tracked")
        await engine.detachKeepingInstances()
    }

    /// Two runners per VM, only the first registered, and idle: registering both is safe, so the VM is registered
    /// again rather than watched as if the set were complete.
    func testPartlyRegisteredIdleVMIsRegisteredAgain() async throws {
        let store = makeTestStore()
        let tart = FakeTart()
        runningTartVM(tart)
        let github = FakeGitHub()
        github.register(name: "kinhin-t1-r1", busy: false)
        var config = makeTestConfig()
        config.vm.ephemeral = true
        config.runnersPerVM = 2
        let ssh = FakeSSH()
        let engine = FleetEngine(
            config: config, github: github, tart: tart, store: store, ssh: ssh, host: host,
            dependencies: .init(lifecycleDrainTimeout: .milliseconds(200)))

        await engine.recoverIfNeeded()

        try await waitUntil(timeout: 5) { !ssh.scripts.isEmpty }
        XCTAssertNotEqual(
            store.all.first { $0.id == "kinhin-t1" }?.phase, .busy,
            "a partly registered idle set is not watched as busy")
        await engine.detachKeepingInstances()
    }

    /// An account that stays unattached past the hold limit is torn down, so a broken token cannot hold a slot and
    /// its disk indefinitely.
    func testHeldInstanceOfAnUnattachedAccountIsTornDownAfterTheHoldLimit() async throws {
        let store = makeTestStore()
        let tart = FakeTart()
        runningTartVM(tart)
        let github = FakeGitHub()
        github.register(name: "kinhin-t1", busy: true)
        var config = makeTestConfig()
        config.vm.ephemeral = true
        let engine = FleetEngine(
            config: config, github: github, tart: tart, store: store, ssh: FakeSSH(), host: host,
            dependencies: .init(
                lifecycleDrainTimeout: .milliseconds(200), watchdog: Watchdog(adoptionHoldLimit: .zero)))
        engine.forgeState.withLock { $0.byPlatform["github"] = nil }

        await engine.recoverIfNeeded()
        let held = store.all.first { $0.id == "kinhin-t1" }?.phase
        XCTAssertEqual(held, .booting, "held while the account is unattached")

        await engine.settleAdoptions()
        try await waitUntil(timeout: 5) { !store.all.contains { $0.id == "kinhin-t1" } }
        await engine.detachKeepingInstances()
    }

    /// An instance whose account is no longer in the config has no forge that will ever answer: it is released at once.
    func testInstanceOfARemovedAccountIsReleasedAtOnce() async throws {
        let store = makeTestStore()
        let tart = FakeTart()
        runningTartVM(tart)
        var config = makeTestConfig()
        config.accounts = []
        let engine = FleetEngine(
            config: config, github: FakeGitHub(), tart: tart, store: store, ssh: FakeSSH(), host: host,
            dependencies: .init(lifecycleDrainTimeout: .milliseconds(200)))

        await engine.recoverIfNeeded()

        try await waitUntil(timeout: 5) { !store.all.contains { $0.id == "kinhin-t1" } }
        await engine.detachKeepingInstances()
    }
}
