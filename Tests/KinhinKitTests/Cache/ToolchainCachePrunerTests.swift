import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The host toolchain-cache pruner: age and size eviction, the grace
/// window, dry runs, and empty-directory cleanup.
final class ToolchainCachePrunerTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-toolchains-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Pruner

    private func makeCache() throws -> (root: URL, pruner: ToolchainCachePruner) {
        let root = scratch.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, ToolchainCachePruner(cacheRoot: root))
    }

    /// Writes a file whose mtime is `ageDays` days in the past.
    private func writeCacheFile(root: URL, relative: String, bytes: Int, ageDays: Double) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        let past = Date().addingTimeInterval(-ageDays * 86_400)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
    }

    func testPruneDeletesOldEntriesButKeepsFreshOnes() throws {
        let (root, pruner) = try makeCache()
        try writeCacheFile(root: root, relative: "npm/old.tar", bytes: 100, ageDays: 40)
        try writeCacheFile(root: root, relative: "npm/new.tar", bytes: 100, ageDays: 1)

        let report = pruner.prune(policy: ToolchainCachePolicy(autoPrune: true, maxAgeDays: 30, maxGB: 0))

        XCTAssertEqual(report.freedBytes, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("npm/old.tar").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("npm/new.tar").path))
    }

    func testPruneEvictsLeastRecentlyUsedBeyondSizeCap() throws {
        let (root, pruner) = try makeCache()
        try writeCacheFile(root: root, relative: "go/mod/old", bytes: 3_000_000_000, ageDays: 20)
        try writeCacheFile(root: root, relative: "npm/pkg", bytes: 3_000_000_000, ageDays: 2)

        // 6 GB total, 4 GB cap → the older entry (3 GB) is evicted.
        let report = pruner.prune(policy: ToolchainCachePolicy(autoPrune: true, maxAgeDays: 0, maxGB: 4))
        XCTAssertEqual(report.freedBytes, 3_000_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("go/mod/old").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("npm/pkg").path))
    }

    func testPruneRespectsGraceWindow() throws {
        let (root, pruner) = try makeCache()
        // Ancient mtime but grace window is computed from the *real* now —
        // write fresh (mid-download simulation): must survive any policy.
        try writeCacheFile(root: root, relative: "fvm/sdk.zip", bytes: 2_000_000_000, ageDays: 0)

        let report = pruner.prune(policy: ToolchainCachePolicy(autoPrune: true, maxAgeDays: 0, maxGB: 1), now: Date())
        XCTAssertTrue(report.entries.isEmpty, "fresh writes are never evicted (grace window)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("fvm/sdk.zip").path))
    }

    func testPruneDryRunReportsWithoutDeleting() throws {
        let (root, pruner) = try makeCache()
        try writeCacheFile(root: root, relative: "npm/old.tar", bytes: 500, ageDays: 90)

        let report = pruner.prune(policy: ToolchainCachePolicy(autoPrune: true, maxAgeDays: 30, maxGB: 0), dryRun: true)
        XCTAssertEqual(report.freedBytes, 500)
        XCTAssertTrue(report.dryRun)
        XCTAssertFalse(report.entries.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("npm/old.tar").path),
            "dry run deletes nothing")
    }

    func testPruneWithoutAutoPruneIsNoopUnlessDryRunRequested() throws {
        let (root, pruner) = try makeCache()
        try writeCacheFile(root: root, relative: "npm/old.tar", bytes: 500, ageDays: 90)

        let report = pruner.prune(policy: ToolchainCachePolicy(autoPrune: false, maxAgeDays: 30, maxGB: 0))
        XCTAssertTrue(report.entries.isEmpty, "auto-prune off → sweep is a no-op")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("npm/old.tar").path))
    }

    func testPruneCleansUpEmptyDirectories() throws {
        let (root, pruner) = try makeCache()
        try writeCacheFile(root: root, relative: "cypress/binary/old.bin", bytes: 100, ageDays: 60)

        _ = pruner.prune(policy: ToolchainCachePolicy(autoPrune: true, maxAgeDays: 30, maxGB: 0))
        var contents: [String] = []
        FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.forEach { item in
            contents.append((item as? URL)?.lastPathComponent ?? "")
        }
        XCTAssertFalse(contents.contains("binary"), "empty dirs left by deletions are removed")
    }

    func testRateLimitedSweepSkipsTheWalkUntilTheIntervalPasses() throws {
        let (root, pruner) = try makeCache()
        let policy = ToolchainCachePolicy(autoPrune: true, maxAgeDays: 30, maxGB: 0)
        try writeCacheFile(root: root, relative: "npm/old1.tar", bytes: 10, ageDays: 60)
        let start = Date()

        let first = pruner.prune(policy: policy, now: start, minInterval: 3600)
        XCTAssertEqual(first.entries.count, 1)

        try writeCacheFile(root: root, relative: "npm/old2.tar", bytes: 10, ageDays: 60)
        let skipped = pruner.prune(policy: policy, now: start.addingTimeInterval(600), minInterval: 3600)
        XCTAssertTrue(skipped.entries.isEmpty, "swept 10 minutes ago: no walk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("npm/old2.tar").path))

        let forced = pruner.prune(policy: policy, now: start.addingTimeInterval(600))
        XCTAssertEqual(forced.entries.count, 1, "no minInterval always sweeps")

        try writeCacheFile(root: root, relative: "npm/old3.tar", bytes: 10, ageDays: 60)
        let later = pruner.prune(policy: policy, now: start.addingTimeInterval(4000), minInterval: 3600)
        XCTAssertEqual(later.entries.count, 1, "an hour on, the sweep runs again")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".last-sweep").path),
            "the marker lives beside the cache, never inside it")
    }

    func testDryRunIgnoresTheRateLimit() throws {
        let (root, pruner) = try makeCache()
        let policy = ToolchainCachePolicy(autoPrune: true, maxAgeDays: 30, maxGB: 0)
        try writeCacheFile(root: root, relative: "npm/old.tar", bytes: 10, ageDays: 60)
        _ = pruner.prune(policy: policy, minInterval: 3600)
        try writeCacheFile(root: root, relative: "npm/old2.tar", bytes: 10, ageDays: 60)
        XCTAssertEqual(pruner.prune(policy: policy, dryRun: true, minInterval: 3600).entries.count, 1)
    }

    func testCachePolicyDefaultsFromConfig() {
        XCTAssertEqual(
            ToolchainCachePolicy(from: nil), ToolchainCachePolicy(autoPrune: true, maxAgeDays: 30, maxGB: 50))
        let partial = KinhinConfig.ToolchainCacheConfig(autoPrune: false, maxAgeDays: 7, maxGB: 0)
        let policy = ToolchainCachePolicy(from: partial)
        XCTAssertEqual(policy, ToolchainCachePolicy(autoPrune: false, maxAgeDays: 7, maxGB: 0))
    }

    // MARK: - Symlink safety

    func testRemovalNeverFollowsADirectorySwappedForASymlink() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("kn-prune-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let cache = base.appendingPathComponent("cache")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: cache.appendingPathComponent("npm"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("precious.txt")
        try Data("keep".utf8).write(to: victim)
        // What a guest does between the walk and the delete: npm/ becomes a link out of the cache.
        try fm.removeItem(at: cache.appendingPathComponent("npm"))
        try fm.createSymbolicLink(at: cache.appendingPathComponent("npm"), withDestinationURL: outside)

        let pruner = ToolchainCachePruner(cacheRoot: cache)
        XCTAssertThrowsError(
            try pruner.removeWithoutFollowingLinks(
                cache.appendingPathComponent("npm/precious.txt"), isDirectory: false))
        XCTAssertTrue(fm.fileExists(atPath: victim.path), "a file outside the cache must survive")
    }

    func testRemovalDeletesARegularFileInsideTheCache() throws {
        let fm = FileManager.default
        let cache = fm.temporaryDirectory.appendingPathComponent("kn-prune-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: cache) }
        let dir = cache.appendingPathComponent("go/mod")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("x.zip")
        try Data("x".utf8).write(to: file)
        let pruner = ToolchainCachePruner(cacheRoot: cache)
        try pruner.removeWithoutFollowingLinks(file, isDirectory: false)
        XCTAssertFalse(fm.fileExists(atPath: file.path))
        try pruner.removeWithoutFollowingLinks(dir, isDirectory: true)
        XCTAssertFalse(fm.fileExists(atPath: dir.path))
    }
}
