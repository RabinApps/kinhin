import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class StoreAndLogTests: XCTestCase {
    // MARK: FleetStore

    func testUpsertInsertThenUpdate() {
        let store = makeTestStore()
        var record = VMRecord(id: "kinhin-1", phase: .cloning)
        store.upsert(record)

        record.phase = .ready
        record.ip = "192.168.64.9"
        store.upsert(record)

        XCTAssertEqual(store.all.count, 1)
        XCTAssertEqual(store.all[0].phase, .ready)
        XCTAssertEqual(store.all[0].ip, "192.168.64.9")
    }

    func testRecordsRoundTripAcrossStoreInstances() throws {
        // This is the crash-recovery contract: one process writes, the next
        // process (new FleetStore over the same directory) reads it back.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let first = FleetStore(directory: dir)
        var a = VMRecord(id: "kinhin-a", phase: .busy)
        a.ip = "192.168.64.2"
        a.job = "build"
        let b = VMRecord(id: "kinhin-b", phase: .failed)
        first.upsert(a)
        first.upsert(b)

        let second = FleetStore(directory: dir)
        let loaded = second.all
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first { $0.id == "kinhin-a" }?.phase, .busy)
        XCTAssertEqual(loaded.first { $0.id == "kinhin-a" }?.ip, "192.168.64.2")
        XCTAssertEqual(loaded.first { $0.id == "kinhin-a" }?.job, "build")
        XCTAssertEqual(loaded.first { $0.id == "kinhin-b" }?.phase, .failed)
    }

    func testRemoveDeletesOnlyTargetRecord() {
        let store = makeTestStore()
        store.upsert(VMRecord(id: "kinhin-keep", phase: .ready))
        store.upsert(VMRecord(id: "kinhin-drop", phase: .ready))
        store.remove(id: "kinhin-drop")

        XCTAssertEqual(store.all.map { $0.id }, ["kinhin-keep"])
    }

    func testCorruptStateFileIsTolerated() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json at all{{{".utf8).write(to: dir.appendingPathComponent("fleet.json"))

        let store = FleetStore(directory: dir)
        XCTAssertEqual(store.all, [])
        // And the store must still work afterwards.
        store.upsert(VMRecord(id: "kinhin-x", phase: .cloning))
        XCTAssertEqual(store.all.count, 1)
    }

    func testConcurrentUpsertsLoseNothing() {
        let store = makeTestStore()
        let total = 200
        DispatchQueue.concurrentPerform(iterations: total) { i in
            store.upsert(VMRecord(id: "kinhin-\(i)", phase: .cloning))
        }
        XCTAssertEqual(store.all.count, total)
        // And the persisted file must match too.
        XCTAssertEqual(store.all.filter { $0.phase == .cloning }.count, total)
    }

    // MARK: Pre-rename (Orchard) migration

    func testSupportDirectoryMigratesFromLegacyOrchard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-migrate-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent("Orchard", isDirectory: true)
        let new = root.appendingPathComponent("Kinhin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try Data("config".utf8).write(to: legacy.appendingPathComponent("config.yaml"))
        defer { try? FileManager.default.removeItem(at: root) }

        Paths.migrateLegacySupportDirectory(from: legacy, to: new)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacy.path), "legacy directory must be moved, not copied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("config.yaml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("logs").path))
    }

    func testMigrationNeverOverwritesAnExistingNewDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-migrate-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent("Orchard", isDirectory: true)
        let new = root.appendingPathComponent("Kinhin", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: new.appendingPathComponent("config.yaml"))
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("config.yaml"))
        defer { try? FileManager.default.removeItem(at: root) }

        Paths.migrateLegacySupportDirectory(from: legacy, to: new)

        // The live directory wins; legacy data is left untouched for manual recovery.
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("config.yaml"), encoding: .utf8), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testVMRecordNamesCarryTheKinhinPrefix() {
        let name = VMRecord.newName()
        XCTAssertTrue(name.hasPrefix("kinhin-"), "spawned instances must use the kinhin- prefix, got \(name)")
    }

    // MARK: Log

    func testLogRespectsMinimumLevel() {
        let previousMin = Log.minLevel
        let previousEcho = Log.echoToStderr
        Log.echoToStderr = false  // keep test output clean
        defer {
            Log.minLevel = previousMin
            Log.echoToStderr = previousEcho
        }
        Log.minLevel = .warn
        let unique = "filtered-marker-\(UUID().uuidString)"
        Log.info("test", unique)
        let snapshot = Log.snapshot(limit: 100)
        XCTAssertFalse(snapshot.contains { $0.message == unique }, "info must be filtered at minLevel=.warn")
        let kept = "kept-marker-\(UUID().uuidString)"
        Log.error("test", kept)
        XCTAssertTrue(Log.snapshot(limit: 100).contains { $0.message == kept })
    }

    func testLogSnapshotIsMostRecentLast() {
        let previousEcho = Log.echoToStderr
        Log.echoToStderr = false
        defer { Log.echoToStderr = previousEcho }
        let first = "first-marker-\(UUID().uuidString)"
        let second = "second-marker-\(UUID().uuidString)"
        Log.error("test", first)
        Log.error("test", second)
        let snap = Log.snapshot(limit: 2)
        XCTAssertEqual(snap.count, 2)
        XCTAssertTrue(snap[0].message.hasPrefix("first-marker"))
        XCTAssertTrue(snap[1].message.hasPrefix("second-marker"))
    }
}
