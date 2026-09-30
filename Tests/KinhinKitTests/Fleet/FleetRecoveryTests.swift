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
        XCTAssertEqual(adopted?.runtime, RuntimeID.tart.rawValue, "a Tart VM must not be adopted as a container")
        await engine.detachKeepingInstances()
    }

    /// A runtime that can't be listed (tart wedged, a daemon down) must not
    /// read as "every instance vanished": its records are kept, not dropped
    /// (which would orphan the running VMs).
    func testRecordsSurviveAFailedListing() async {
        let store = makeTestStore()
        var record = VMRecord(id: "kinhin-t2", phase: .busy)
        record.runtime = RuntimeID.tart.rawValue
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
        XCTAssertEqual(record?.runtime, RuntimeID.tart.rawValue)
        await engine.detachKeepingInstances()
    }

    func testRecordWithRuntimeIsLeftAsIs() async {
        let store = makeTestStore()
        var record = VMRecord(id: "kinhin-t1", phase: .ready)
        record.runtime = RuntimeID.tart.rawValue
        store.upsert(record)
        let (engine, _) = makeMixedEngine(store: store)

        await engine.recoverIfNeeded()

        XCTAssertEqual(store.all.map(\.id), ["kinhin-t1"])
        XCTAssertEqual(store.all.first?.runtime, RuntimeID.tart.rawValue)
        await engine.detachKeepingInstances()
    }
}
