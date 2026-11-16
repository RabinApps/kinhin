import CryptoKit
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The Docker Hub cache's data directory checked from the host: a link whose blob the proxy TTL expired (the
/// `unexpected EOF` of #107), an empty blob, a corrupt blob and a tag whose manifest is gone are found, and a repair
/// deletes exactly those entries so the next pull fetches them from Docker Hub again.
final class DockerRegistryCacheStorageTests: XCTestCase {
    private var dataDirectory: URL!
    private var root: URL { DockerRegistryCacheStorage.storageRoot(in: dataDirectory) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("registry-storage-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        dataDirectory = dir.appendingPathComponent("registry-cache", isDirectory: true)
    }

    // MARK: - Building a registry layout

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes a blob and returns its digest.
    @discardableResult
    private func blob(_ bytes: Data, as digest: String? = nil) throws -> String {
        let digest = digest ?? Self.digest(bytes)
        let directory = DockerRegistryCacheStorage.blobDirectory(for: digest, in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent("data"))
        return digest
    }

    /// Writes a link file at `path` (under `repositories/`) naming `digest`, and returns it.
    @discardableResult
    private func link(_ path: String, to digest: String) throws -> URL {
        let url = root.appendingPathComponent("repositories/\(path)/link")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "sha256:\(digest)".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func layer(_ repository: String, _ digest: String) throws -> URL {
        try link("\(repository)/_layers/sha256/\(digest)", to: digest)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - Scanning

    func testAnEmptyOrMissingDirectoryIsHealthy() {
        let report = DockerRegistryCacheStorage.scan(dataDirectory)
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.links, 0)
        XCTAssertEqual(report.blobs, 0)
    }

    func testIntactLinksAndBlobsAreHealthy() throws {
        let shared = try blob(Data("shared layer".utf8))
        try layer("library/golang", shared)
        try layer("library/debian", shared)
        let manifest = try blob(Data(#"{"schemaVersion":2}"#.utf8))
        try link("library/golang/_manifests/revisions/sha256/\(manifest)", to: manifest)
        try link("library/golang/_manifests/tags/1.25-bookworm/current", to: manifest)
        let report = DockerRegistryCacheStorage.scan(dataDirectory, verifyDigests: true)
        XCTAssertTrue(report.isHealthy, "\(report)")
        XCTAssertEqual(report.links, 4)
        XCTAssertEqual(report.blobs, 2)
    }

    func testALinkToAnExpiredSharedBlobDangles() throws {
        // The proxy TTL expired the blob through one repository; the other repositories' links stay behind.
        let expired = String(repeating: "4f", count: 32)
        let golang = try layer("library/golang", expired)
        let kept = try blob(Data("still here".utf8))
        try layer("library/golang", kept)
        let report = DockerRegistryCacheStorage.scan(dataDirectory)
        XCTAssertEqual(report.danglingLinks, ["repositories/library/golang/_layers/sha256/\(expired)/link"])
        XCTAssertEqual(report.problems, 1)
        XCTAssertTrue(exists(golang), "a scan changes nothing")
    }

    func testAnEmptyBlobIsBrokenUnlessItIsTheEmptyDigest() throws {
        let empty = try blob(Data(), as: String(repeating: "ab", count: 32))
        let reference = try layer("library/alpine", empty)
        try blob(Data())  // sha256 of no bytes: legitimately empty
        let report = DockerRegistryCacheStorage.scan(dataDirectory)
        XCTAssertEqual(report.brokenBlobs, ["blobs/sha256/ab/\(empty)"])
        XCTAssertEqual(report.danglingLinks, ["repositories/library/alpine/_layers/sha256/\(empty)/link"])
        XCTAssertTrue(exists(reference))
    }

    func testDigestVerificationFindsCorruptBytesOnlyWhenAsked() throws {
        let claimed = Self.digest(Data("the real layer".utf8))
        try blob(Data("something else".utf8), as: claimed)
        try layer("library/node", claimed)
        XCTAssertTrue(DockerRegistryCacheStorage.scan(dataDirectory).isHealthy, "sizes alone look fine")
        let verified = DockerRegistryCacheStorage.scan(dataDirectory, verifyDigests: true)
        XCTAssertEqual(verified.corruptBlobs, ["blobs/sha256/\(claimed.prefix(2))/\(claimed)"])
        XCTAssertEqual(verified.danglingLinks.count, 1, "the link to a corrupt blob is broken too")
    }

    func testALinkThatNamesNoDigestDangles() throws {
        let url = root.appendingPathComponent("repositories/library/rust/_layers/sha256/zz/link")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "garbage".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(DockerRegistryCacheStorage.scan(dataDirectory).danglingLinks.count, 1)
    }

    func testASymlinkedDataDirectoryIsFollowed() throws {
        // The data directory moved to an external disk and left a symlink behind, as on a Mac whose cache moved.
        let link = dataDirectory.appendingPathExtension("link")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dataDirectory)
        try layer("library/python", String(repeating: "cd", count: 32))
        XCTAssertEqual(DockerRegistryCacheStorage.scan(link).danglingLinks.count, 1)
        XCTAssertGreaterThan(DockerRegistryCache.dataBytes(at: link) ?? 0, 0, "the size is read through the symlink")
    }

    // MARK: - Repairing

    func testRepairDeletesExactlyTheBrokenEntries() throws {
        let kept = try blob(Data("kept".utf8))
        let keptLink = try layer("library/golang", kept)
        let expired = String(repeating: "4f", count: 32)
        let dangling = try layer("library/golang", expired)
        let emptyBlob = try blob(Data(), as: String(repeating: "ab", count: 32))
        let toEmpty = try layer("library/debian", emptyBlob)
        let report = DockerRegistryCacheStorage.scan(dataDirectory)
        XCTAssertEqual(report.problems, 3)

        XCTAssertEqual(DockerRegistryCacheStorage.repair(report, in: dataDirectory), 3)
        XCTAssertFalse(exists(dangling.deletingLastPathComponent()), "the link's <digest>/ directory goes")
        XCTAssertFalse(exists(toEmpty.deletingLastPathComponent()))
        XCTAssertFalse(exists(DockerRegistryCacheStorage.blobDirectory(for: emptyBlob, in: root)))
        XCTAssertTrue(exists(keptLink), "intact entries stay")
        XCTAssertTrue(exists(DockerRegistryCacheStorage.blobDirectory(for: kept, in: root)))
        XCTAssertTrue(DockerRegistryCacheStorage.scan(dataDirectory).isHealthy)
    }

    func testATagWhoseManifestIsGoneLosesTheWholeTag() throws {
        let gone = String(repeating: "ef", count: 32)
        let current = try link("library/golang/_manifests/tags/1.25-bookworm/current", to: gone)
        let report = DockerRegistryCacheStorage.scan(dataDirectory)
        XCTAssertEqual(report.danglingLinks.count, 1)
        DockerRegistryCacheStorage.repair(report, in: dataDirectory)
        let tag = current.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(tag.lastPathComponent, "1.25-bookworm")
        XCTAssertFalse(exists(tag), "the proxy asks Docker Hub for the tag again")
        XCTAssertTrue(exists(tag.deletingLastPathComponent()), "other tags' directory stays")
    }

    func testRepairCountsAnEntryAlreadyGone() throws {
        let missing = String(repeating: "12", count: 32)
        let dangling = try layer("library/mysql", missing)
        let report = DockerRegistryCacheStorage.scan(dataDirectory)
        try FileManager.default.removeItem(at: dangling.deletingLastPathComponent())
        XCTAssertEqual(DockerRegistryCacheStorage.repair(report, in: dataDirectory), 1)
    }

    // MARK: - The cache checks before handing out its address

    func testARunnerAskingForTheCacheGetsBrokenEntriesDeletedAtMostEveryInterval() async throws {
        let missing = String(repeating: "4f", count: 32)
        let dangling = try layer("library/golang", missing)
        let cache = DockerRegistryCache(shell: FakeShell(), binPath: "/x", dataDirectory: dataDirectory)
        let start = ContinuousClock.now
        await cache.checkStorageIfDue(now: start)
        XCTAssertFalse(exists(dangling), "deleted on the first check")

        let again = try layer("library/golang", missing)
        await cache.checkStorageIfDue(now: start + .seconds(10))
        XCTAssertTrue(exists(again), "not checked again within the interval")
        await cache.checkStorageIfDue(now: start + DockerRegistryCache.storageCheckInterval)
        XCTAssertFalse(exists(again))
    }
}
