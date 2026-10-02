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
}
