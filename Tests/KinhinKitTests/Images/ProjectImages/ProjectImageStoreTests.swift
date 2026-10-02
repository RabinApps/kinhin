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
