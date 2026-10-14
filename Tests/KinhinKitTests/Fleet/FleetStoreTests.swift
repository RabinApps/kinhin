import XCTest

@testable import KinhinKit

final class FleetStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kn-store-\(UUID().uuidString)")
        try Paths.createPrivateDirectory(root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Concurrent mutations of one record must all land: a read-then-upsert
    /// would lose some of them.
    func testConcurrentUpdatesAreNotLost() async {
        let store = FleetStore(directory: root)
        store.upsert(VMRecord(id: "kinhin-1-a", phase: .ready))
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask { store.update(id: "kinhin-1-a") { $0.job = ($0.job ?? "") + "\(index)," } }
            }
        }
        let job = store.all.first?.job ?? ""
        XCTAssertEqual(job.split(separator: ",").count, 50)
    }

    func testUpdateNeverResurrectsARemovedRecord() {
        let store = FleetStore(directory: root)
        store.upsert(VMRecord(id: "kinhin-1-a"))
        store.remove(id: "kinhin-1-a")
        XCTAssertFalse(store.update(id: "kinhin-1-a") { $0.phase = .busy })
        XCTAssertTrue(store.all.isEmpty)
    }

    func testNoOpUpdateDoesNotRestampOrWrite() throws {
        let store = FleetStore(directory: root)
        store.upsert(VMRecord(id: "kinhin-1-a", phase: .ready))
        let before = store.all.first?.updatedAt
        let file = root.appendingPathComponent("fleet.json")
        let written = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        store.update(id: "kinhin-1-a") { $0.phase = .ready }
        XCTAssertEqual(store.all.first?.updatedAt, before)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(written, after)
    }

    /// The file on disk always reflects the last committed state.
    func testPersistedFileMatchesLatestState() async throws {
        let store = FleetStore(directory: root)
        store.upsert(VMRecord(id: "kinhin-1-a", phase: .cloning))
        await withTaskGroup(of: Void.self) { group in
            for phase in [VMPhase.booting, .registering, .ready, .busy] {
                group.addTask { store.update(id: "kinhin-1-a") { $0.phase = phase } }
            }
        }
        let data = try Data(contentsOf: root.appendingPathComponent("fleet.json"))
        let onDisk = try JSONDecoder().decode([VMRecord].self, from: data)
        XCTAssertEqual(onDisk, store.all)
    }

    // MARK: - Corrupt file

    private func corruptCopies() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("fleet.json.corrupt-") }
    }

    /// A corrupt fleet.json is moved aside, not overwritten by the next save,
    /// and the store reports where it went.
    func testCorruptFileIsQuarantinedAndSurvivesTheNextSave() throws {
        let garbage = Data("{not json".utf8)
        try garbage.write(to: root.appendingPathComponent("fleet.json"))

        let store = FleetStore(directory: root)

        XCTAssertTrue(store.all.isEmpty)
        let copies = try corruptCopies()
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(store.recoveredFromCorruptFile?.lastPathComponent, copies.first?.lastPathComponent)
        store.upsert(VMRecord(id: "kinhin-1-a"))
        let copy = try XCTUnwrap(copies.first)
        XCTAssertEqual(try Data(contentsOf: copy), garbage, "the next save must not touch the kept copy")
        XCTAssertEqual(FleetStore(directory: root).all.map(\.id), ["kinhin-1-a"])
    }

    func testMissingFileIsNotQuarantined() throws {
        let store = FleetStore(directory: root)
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertNil(store.recoveredFromCorruptFile)
        store.reload()
        XCTAssertNil(store.recoveredFromCorruptFile)
        XCTAssertEqual(try corruptCopies(), [])
    }

    /// A corrupt file at reload keeps the in-memory records but is still set
    /// aside and reported.
    func testCorruptFileAtReloadKeepsRecordsAndQuarantines() throws {
        let store = FleetStore(directory: root)
        store.upsert(VMRecord(id: "kinhin-1-a"))
        try Data("garbage".utf8).write(to: root.appendingPathComponent("fleet.json"))

        store.reload()

        XCTAssertEqual(store.all.map(\.id), ["kinhin-1-a"])
        XCTAssertEqual(try corruptCopies().count, 1)
        XCTAssertNotNil(store.recoveredFromCorruptFile)
    }
}
