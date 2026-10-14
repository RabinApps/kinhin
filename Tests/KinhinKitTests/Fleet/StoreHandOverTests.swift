import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// In production the replacement engine builds its own `FleetStore` while the
/// old engine is still running. Records the old engine creates in that window
/// must survive the hand-over with everything they carry.
final class StoreHandOverTests: XCTestCase {
    let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kn-handover-\(UUID().uuidString)")
        try Paths.createPrivateDirectory(directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEngine(store: FleetStore, tart: FakeTart) -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(), github: FakeGitHub(), tart: tart, store: store, ssh: FakeSSH(), host: host,
            dependencies: .init(
                tokenLoader: { _, _ in "t" }, lifecycleDrainTimeout: .milliseconds(200),
                exitWatchInterval: .milliseconds(20)))
    }

    func testLaunchAdoptsRecordsWrittenAfterTheStoreWasConstructed() async {
        let tart = FakeTart()
        tart.blockIP()
        tart.vms["kinhin-live"] = TartVM(name: "kinhin-live", source: "tahoe-base", status: "running")

        // The replacement's store is built first (as `FleetEngine.production` does) ...
        let replacementStore = FleetStore(directory: directory)
        let replacement = makeEngine(store: replacementStore, tart: tart)
        XCTAssertTrue(replacementStore.all.isEmpty)

        // ... then the old engine, still serving, creates a record.
        let oldStore = FleetStore(directory: directory)
        var created = VMRecord(id: "kinhin-live", phase: .registering)
        created.platform = "github"
        created.runtimeID = .tart
        created.image = "xcode-derived"
        oldStore.upsert(created)

        replacement.markRunning()
        await replacement.launch()
        let adopted = replacementStore.all.first { $0.id == "kinhin-live" }
        XCTAssertEqual(adopted?.platform, "github", "the account survives, so the lifecycle does not default it")
        XCTAssertEqual(adopted?.image, "xcode-derived", "the image the instance was cloned from survives")
        XCTAssertEqual(adopted?.runtimeID, .tart)
        await replacement.detachKeepingInstances()
        tart.releaseIP("192.168.64.9")
    }

    func testReloadKeepsMemoryWhenTheFileIsMissingOrCorrupt() throws {
        let store = FleetStore(directory: directory)
        store.upsert(VMRecord(id: "kinhin-1", phase: .ready))
        let file = directory.appendingPathComponent("fleet.json")
        try Data("not json".utf8).write(to: file)
        store.reload()
        XCTAssertEqual(store.all.map(\.id), ["kinhin-1"], "an unreadable file must not wipe the fleet")
        // The unreadable file was moved aside, so the next reload finds none.
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "a corrupt file is quarantined")
        store.reload()
        XCTAssertEqual(store.all.map(\.id), ["kinhin-1"], "a failed write must not wipe the fleet")
    }
}
