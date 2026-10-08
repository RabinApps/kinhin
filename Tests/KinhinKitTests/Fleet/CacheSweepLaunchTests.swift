import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The host-cache sweep runs when the marker says it is due (including right
/// at launch), not only after a full day of one engine's uptime.
final class CacheSweepLaunchTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-sweep-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func writeOld(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        let past = Date().addingTimeInterval(-90 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        return url
    }

    private func makeEngine() -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(), github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(),
            ssh: FakeSSH(), host: testHost)
    }

    func testADueSweepRunsImmediatelyAndAnotherEngineWithinADayDoesNot() async throws {
        let root = scratch.appendingPathComponent("cache", isDirectory: true)
        let first = try writeOld("npm/first.tar", in: root)
        let pruner = ToolchainCachePruner(cacheRoot: root)
        XCTAssertTrue(pruner.isSweepDue(minInterval: FleetEngine.cacheSweepInterval))

        await makeEngine().runCacheSweep(pruner: pruner)  // launch of the first engine
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the due sweep ran at launch")
        XCTAssertFalse(pruner.isSweepDue(minInterval: FleetEngine.cacheSweepInterval))

        let second = try writeOld("npm/second.tar", in: root)
        await makeEngine().runCacheSweep(pruner: pruner)  // a rebuilt engine, the same day
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "the marker spares the repeat walk")
    }

    func testSweepDueFollowsTheMarkerAge() throws {
        let root = scratch.appendingPathComponent("cache", isDirectory: true)
        _ = try writeOld("npm/a.tar", in: root)
        let pruner = ToolchainCachePruner(cacheRoot: root)
        let policy = ToolchainCachePolicy(autoPrune: true, maxAgeDays: 30, maxGB: 0)
        let start = Date()
        pruner.prune(policy: policy, now: start, minInterval: 3600)

        XCTAssertFalse(pruner.isSweepDue(minInterval: 3600, now: start.addingTimeInterval(60)))
        XCTAssertTrue(pruner.isSweepDue(minInterval: 3600, now: start.addingTimeInterval(3601)))
    }
}
