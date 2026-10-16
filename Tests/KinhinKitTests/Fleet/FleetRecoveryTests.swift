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
}
