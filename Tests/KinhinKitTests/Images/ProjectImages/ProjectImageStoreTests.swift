import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ProjectImageStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-pis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)  // test temp dir
    }

    private func record(_ name: String, used: Date) -> ProjectImageRecord {
        ProjectImageRecord(
            name: name, key: name, base: "b", summary: "", createdAt: used, lastUsedAt: used,
            toolchains: .init(KinhinConfig.ToolchainsConfig()), shareCache: false)
    }

    func testPersistsAcrossInstances() {
        let store = ProjectImageStore(directory: dir)
        store.upsert(record("a", used: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(ProjectImageStore(directory: dir).all.map(\.name), ["a"])
    }

    /// A queue of jobs touches the same image every poll: the index is
    /// rewritten only when the stamp is more than ~10 minutes old.
    func testTouchPersistsOnlyWhenTheStampIsStale() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let store = ProjectImageStore(directory: dir)
        store.upsert(record("a", used: start))

        store.touch("a", now: start.addingTimeInterval(60))
        XCTAssertEqual(store.record(named: "a")?.lastUsedAt, start, "touched a minute ago: no write")
        XCTAssertEqual(ProjectImageStore(directory: dir).record(named: "a")?.lastUsedAt, start)

        let later = start.addingTimeInterval(700)
        store.touch("a", now: later)
        XCTAssertEqual(store.record(named: "a")?.lastUsedAt, later)
        XCTAssertEqual(ProjectImageStore(directory: dir).record(named: "a")?.lastUsedAt, later, "persisted")
    }

    func testPruneRemovesLeastRecentlyUsedBeyondLimitAndSkipsProtected() {
        let store = ProjectImageStore(directory: dir)
        for (i, name) in ["old", "mid", "new"].enumerated() {
            store.upsert(record(name, used: Date(timeIntervalSince1970: Double(i) * 1000)))
        }
        XCTAssertEqual(store.pruneCandidates(maxImages: 2, maxAgeDays: 0, protected: []), ["old"])
        XCTAssertEqual(store.pruneCandidates(maxImages: 2, maxAgeDays: 0, protected: ["old"]), ["mid"])
    }

    func testPruneByAge() {
        let store = ProjectImageStore(directory: dir)
        let now = Date(timeIntervalSince1970: 10 * 86_400)
        store.upsert(record("stale", used: Date(timeIntervalSince1970: 0)))
        store.upsert(record("fresh", used: now))
        XCTAssertEqual(store.pruneCandidates(maxImages: 0, maxAgeDays: 5, protected: [], now: now), ["stale"])
    }

    // MARK: - Corrupt file

    private func corruptCopies() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("project-images.json.corrupt-") }
    }

    func testCorruptFileIsQuarantinedAndSurvivesTheNextSave() throws {
        let garbage = Data("[{\"name\": 1".utf8)
        try garbage.write(to: dir.appendingPathComponent("project-images.json"))

        let store = ProjectImageStore(directory: dir)

        XCTAssertTrue(store.all.isEmpty)
        let copy = try XCTUnwrap(try corruptCopies().first)
        XCTAssertEqual(try corruptCopies().count, 1)
        XCTAssertEqual(store.recoveredFromCorruptFile?.lastPathComponent, copy.lastPathComponent)
        store.upsert(record("a", used: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(try Data(contentsOf: copy), garbage, "the next save must not touch the kept copy")
        XCTAssertEqual(ProjectImageStore(directory: dir).all.map(\.name), ["a"])
    }

    func testMissingFileIsNotQuarantined() throws {
        let store = ProjectImageStore(directory: dir)
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertNil(store.recoveredFromCorruptFile)
        XCTAssertEqual(try corruptCopies(), [])
    }
}

final class ProjectImageInvalidateTests: XCTestCase {
    func testInvalidateBaseDeletesOnlyThatBasesDerivedImages() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-inv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectImageStore(directory: dir)
        func record(_ name: String, base: String) -> ProjectImageRecord {
            ProjectImageRecord(
                name: name, key: name, base: base, summary: "", createdAt: Date(), lastUsedAt: Date(),
                toolchains: .init(KinhinConfig.ToolchainsConfig()), shareCache: false)
        }
        store.upsert(record("main-p1", base: "main"))
        store.upsert(record("xcode-p2", base: "xcode"))
        let tart = FakeTart()

        await ProjectImageService.invalidate(base: "xcode", tart: tart, store: store)

        XCTAssertEqual(tart.deleteCalls, ["xcode-p2"])
        XCTAssertEqual(store.all.map(\.name), ["main-p1"])
    }
}
