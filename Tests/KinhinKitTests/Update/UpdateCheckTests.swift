import CryptoKit
import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class UpdateCheckTests: XCTestCase {
    /// This test's own download directory: tests run in parallel processes and must not see each other's downloads.
    private let downloadRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("kinhin-update-tests-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        StubProtocol.handler = nil
        try? FileManager.default.removeItem(at: downloadRoot)
        super.tearDown()
    }

    func makeChecker(version: String = "0.1.0", repo: String = "acme/kinhin") -> UpdateChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return UpdateChecker(
            repo: repo, currentVersion: version, session: URLSession(configuration: config), downloadRoot: downloadRoot)
    }

    func releaseJSON(tag: String, assets: [String]) -> Data {
        let assetList =
            assets
            .map {
                "{\"name\":\"\($0)\",\"browser_download_url\":\"https://github.com/acme/kinhin/releases/download/\(tag)/\($0)\"}"
            }
            .joined(separator: ",")
        return Data(
            """
            {"tag_name":"\(tag)","name":"kinhin \(tag)","html_url":"https://github.com/acme/kinhin/releases/tag/\(tag)","published_at":"2026-09-01T00:00:00Z","body":"release notes","assets":[\(assetList)]}
            """.utf8)
    }

    // MARK: - Version comparison

    func testVersionComparison() {
        XCTAssertTrue(isVersion("0.1.0", olderThan: "0.2.0"))
        XCTAssertTrue(isVersion("0.9.9", olderThan: "1.0.0"))
        XCTAssertTrue(isVersion("0.9", olderThan: "0.10"))  // numeric, not lexicographic
        XCTAssertTrue(isVersion("1.0.0-beta", olderThan: "1.0.0"))  // pre-release sorts below
        XCTAssertTrue(isVersion("1.0.0", olderThan: "1.0.1"))

        XCTAssertFalse(isVersion("1.0.0", olderThan: "1.0.0"))
        XCTAssertFalse(isVersion("1.0", olderThan: "1.0.0"))  // missing segment == 0
        XCTAssertFalse(isVersion("1.0.0", olderThan: "1.0.0-beta"))
        XCTAssertFalse(isVersion("0.2.0", olderThan: "0.1.0"))
    }

    // MARK: - Release parsing

    func testFetchLatestReleaseParsesDMGAsset() async throws {
        // Hoisted so the @Sendable stub handler doesn't capture self.
        let release = releaseJSON(
            tag: "v0.2.0",
            assets: [
                "kinhin-cli-0.2.0-arm64.zip",
                "kinhin-0.2.0-arm64.dmg",
                "checksums.txt",
            ])
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/acme/kinhin/releases/latest")
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.lowercased().contains("kinhin") ?? false)
            return (200, release, [:])
        }
        let info = try await makeChecker().fetchLatestRelease()
        XCTAssertEqual(info.tag, "v0.2.0")
        XCTAssertEqual(info.version, "0.2.0")
        XCTAssertEqual(info.dmgName, "kinhin-0.2.0-arm64.dmg")
        XCTAssertEqual(
            info.dmgURL.absoluteString,
            "https://github.com/acme/kinhin/releases/download/v0.2.0/kinhin-0.2.0-arm64.dmg")
        XCTAssertEqual(
            info.releaseURL.absoluteString,
            "https://github.com/acme/kinhin/releases/tag/v0.2.0")
        XCTAssertNotNil(info.publishedAt)
    }

    func testDifferentlyNamedDMGIsNotOffered() async {
        let release = releaseJSON(tag: "v0.2.0", assets: ["kinhin-0.1.0-arm64.dmg", "kinhin-nightly-arm64.dmg"])
        StubProtocol.handler = { _ in (200, release, [:]) }
        do {
            _ = try await makeChecker(version: "0.1.0").check()
            XCTFail("only kinhin-<tag version>-arm64.dmg may be offered")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .noDMGAsset("v0.2.0"))
        }
    }

    func testMalformedReleaseTagIsRefused() async {
        for tag in ["v0.2", "latest", "v0.2.0-rc1"] {
            let release = releaseJSON(tag: tag, assets: ["kinhin-0.2.0-arm64.dmg"])
            StubProtocol.handler = { _ in (200, release, [:]) }
            do {
                _ = try await makeChecker(version: "0.1.0").check()
                XCTFail("accepted tag \(tag)")
            } catch {
                XCTAssertEqual(error as? UpdateCheckError, .invalidTag(tag))
            }
        }
    }

    func testBetaVersionOrdering() {
        XCTAssertTrue(isVersion("0.0.1-beta-1", olderThan: "0.0.1-beta-2"))
        XCTAssertTrue(isVersion("0.0.1-beta-2", olderThan: "0.0.1-beta-10"))  // numeric, not lexicographic
        XCTAssertTrue(isVersion("0.0.1-beta-10", olderThan: "0.0.1"))
        XCTAssertFalse(isVersion("0.0.1", olderThan: "0.0.1-beta-1"))
    }

    // MARK: - Check outcomes

    func testBetaBuildListsReleasesAndSeesPrerelease() async throws {
        let release = releaseJSON(tag: "v0.0.1-beta-2", assets: ["kinhin-0.0.1-beta-2-arm64.dmg"])
        let list = Data("[".utf8) + release + Data("]".utf8)
        let path = Locked<String?>(nil)
        StubProtocol.handler = { request in
            path.withLock { $0 = request.url?.path }
            return (200, list, [:])
        }
        let result = try await makeChecker(version: "0.0.1-beta-1").check()
        guard case .available(let info) = result else { return XCTFail("expected available, got \(result)") }
        XCTAssertEqual(info.version, "0.0.1-beta-2")
        XCTAssertEqual(path.withLock { $0 }, "/repos/acme/kinhin/releases")
    }

    func testCheckReturnsAvailableWhenRunningOlder() async throws {
        let release = releaseJSON(tag: "v0.2.0", assets: ["kinhin-0.2.0-arm64.dmg"])
        StubProtocol.handler = { _ in (200, release, [:]) }
        let result = try await makeChecker(version: "0.1.0").check()
        guard case .available(let info) = result else { return XCTFail("expected available, got \(result)") }
        XCTAssertEqual(info.version, "0.2.0")
    }

    func testCheckUpToDateWhenSameVersion() async throws {
        let release = releaseJSON(tag: "v0.1.0", assets: ["kinhin-0.1.0-arm64.dmg"])
        StubProtocol.handler = { _ in (200, release, [:]) }
        let result = try await makeChecker(version: "0.1.0").check()
        XCTAssertEqual(result, .upToDate)
    }

    func testCheckUpToDateWhenRunningAheadOfLatest() async throws {
        // Dev build ahead of the published release must not nag.
        let release = releaseJSON(tag: "v0.1.0", assets: ["kinhin-0.1.0-arm64.dmg"])
        StubProtocol.handler = { _ in (200, release, [:]) }
        let result = try await makeChecker(version: "0.2.0").check()
        XCTAssertEqual(result, .upToDate)
    }

    // MARK: - Error paths

    func testMissingReleaseThrowsNotFound() async {
        StubProtocol.handler = { _ in (404, Data("{}".utf8), [:]) }
        do {
            _ = try await makeChecker().check()
            XCTFail("should throw")
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, .notFound("acme/kinhin"))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testReleaseWithoutDMGAssetThrows() async {
        let release = releaseJSON(tag: "v0.2.0", assets: ["checksums.txt"])
        StubProtocol.handler = { _ in (200, release, [:]) }
        do {
            _ = try await makeChecker().check()
            XCTFail("should throw")
        } catch let error as UpdateCheckError {
            guard case .noDMGAsset(let tag) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(tag, "v0.2.0")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testNetworkFailureSurfacesAsThrownError() async {
        StubProtocol.handler = nil  // StubProtocol fails the request with URLError
        do {
            _ = try await makeChecker().check()
            XCTFail("should throw")
        } catch {
            // Any network-layer error is acceptable: the app logs and stays silent.
        }
    }

    // MARK: - Download

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeInfo(withChecksums: Bool = true) -> UpdateInfo {
        UpdateInfo(
            tag: "v0.2.0",
            version: "0.2.0",
            dmgName: "kinhin-0.2.0-arm64.dmg",
            dmgURL: URL(string: "https://example.com/kinhin-0.2.0-arm64.dmg")!,
            checksumsURL: withChecksums ? URL(string: "https://example.com/checksums.txt") : nil,
            releaseURL: URL(string: "https://example.com/releases/v0.2.0")!,
            publishedAt: nil,
            notes: nil
        )
    }

    /// Serves `payload` for the DMG and `checksums` for checksums.txt.
    private func stubDownload(payload: Data, checksums: String) {
        StubProtocol.handler = { request in
            if request.url?.lastPathComponent == "checksums.txt" { return (200, Data(checksums.utf8), [:]) }
            return (200, payload, [:])
        }
    }

    func testDownloadDMGWritesUnquarantinedFile() async throws {
        let payload = Data("fake dmg bytes".utf8)
        stubDownload(
            payload: payload,
            checksums: "\(sha256Hex(payload))  kinhin-0.2.0-arm64.dmg\n0000  install.sh\n")
        // The download closure runs off the main actor; the reports are a
        // smoke check only (progress may not fire for tiny payloads).
        let progressReports = ProgressReports()
        let url = try await makeChecker().downloadDMG(makeInfo()) { progressReports.append($0) }
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try Data(contentsOf: url), payload)
        // Ground truth for Gatekeeper: the com.apple.quarantine xattr must be absent.
        let quarantineSize = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        XCTAssertEqual(quarantineSize, -1, "downloads must not carry the quarantine attribute")
        _ = progressReports.values  // progress may or may not fire for tiny payloads
    }

    func testDownloadRejectsChecksumMismatchAndDeletesFile() async {
        stubDownload(
            payload: Data("tampered".utf8), checksums: "\(sha256Hex(Data("genuine".utf8)))  kinhin-0.2.0-arm64.dmg\n")
        do {
            _ = try await makeChecker().downloadDMG(makeInfo())
            XCTFail("a mismatching download must throw")
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, .checksumMismatch("kinhin-0.2.0-arm64.dmg"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let leftover =
            (try? FileManager.default.contentsOfDirectory(at: downloadRoot, includingPropertiesForKeys: nil))?
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("kinhin-0.2.0-arm64.dmg").path) }
        XCTAssertEqual(leftover?.count, 0, "unverified installer must not stay on disk")
    }

    func testDownloadFailsClosedWithoutChecksumsAsset() async {
        stubDownload(payload: Data("bytes".utf8), checksums: "")
        do {
            _ = try await makeChecker().downloadDMG(makeInfo(withChecksums: false))
            XCTFail("a release without checksums must not be installable")
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, .noChecksum("kinhin-0.2.0-arm64.dmg"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDownloadFailsClosedWhenChecksumsHasNoEntryForTheDMG() async {
        stubDownload(payload: Data("bytes".utf8), checksums: "abcd  install.sh\n")
        do {
            _ = try await makeChecker().downloadDMG(makeInfo())
            XCTFail("a missing entry must not be treated as verified")
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, .noChecksum("kinhin-0.2.0-arm64.dmg"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testExpectedChecksumParsingHandlesBinaryMarkerAndCase() {
        let text = "ABCDEF  other.zip\n1234ab *kinhin-0.2.0-arm64.dmg\n"
        XCTAssertEqual(UpdateChecker.expectedChecksum(for: "kinhin-0.2.0-arm64.dmg", in: text), "1234ab")
        XCTAssertEqual(UpdateChecker.expectedChecksum(for: "other.zip", in: text), "abcdef")
        XCTAssertNil(UpdateChecker.expectedChecksum(for: "missing.dmg", in: text))
    }

    func testFetchLatestReleaseCapturesChecksumsAsset() async throws {
        let release = releaseJSON(tag: "v0.2.0", assets: ["kinhin-0.2.0-arm64.dmg", "checksums.txt"])
        StubProtocol.handler = { _ in (200, release, [:]) }
        let info = try await makeChecker().fetchLatestRelease()
        XCTAssertEqual(info.checksumsURL?.lastPathComponent, "checksums.txt")
    }
}

/// Progress callbacks arrive off the test's thread: keep them behind a lock.
private final class ProgressReports: Sendable {
    private let storage = Mutex<[Double]>([])
    var values: [Double] { storage.withLock { $0 } }
    func append(_ value: Double) { storage.withLock { $0.append(value) } }
}
