import CryptoKit
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class UpdateTrustTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private let dmgName = "kinhin-0.2.0-arm64.dmg"

    private func makeChecker(shell: FakeShell, teamID: String?) -> UpdateChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return UpdateChecker(
            repo: "acme/kinhin", currentVersion: "0.1.0", session: URLSession(configuration: config), shell: shell,
            trustedTeamID: teamID)
    }

    private func makeInfo() -> UpdateInfo {
        UpdateInfo(
            tag: "v0.2.0", version: "0.2.0", dmgName: dmgName,
            dmgURL: URL(string: "https://github.com/acme/kinhin/releases/download/v0.2.0/\(dmgName)")!,
            checksumsURL: URL(string: "https://github.com/acme/kinhin/releases/download/v0.2.0/checksums.txt"),
            releaseURL: URL(string: "https://github.com/acme/kinhin/releases/tag/v0.2.0")!,
            publishedAt: nil, notes: nil)
    }

    private func stubDownload(payload: Data) {
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        StubProtocol.handler = { request in
            if request.url?.lastPathComponent == "checksums.txt" {
                return (200, Data("\(digest)  kinhin-0.2.0-arm64.dmg\n".utf8), [:])
            }
            return (200, payload, [:])
        }
    }

    private func tempDMG() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-update-\(dmgName)")
    }

    // MARK: - Validators

    func testRepoValidation() {
        XCTAssertTrue(UpdateTrust.isValidRepo("RabinApps/kinhin"))
        XCTAssertTrue(UpdateTrust.isValidRepo("a.b/c_d-e"))
        for bad in ["", "owner", "a/b/c", "a/..", "../b", "a/b?x=1", "a/b#f", "a /b", "a/b\n"] {
            XCTAssertFalse(UpdateTrust.isValidRepo(bad), bad)
        }
    }

    func testAssetNameValidation() {
        XCTAssertTrue(UpdateTrust.isSafeAssetName("kinhin-0.2.0-arm64.dmg"))
        for bad in ["", "../x.dmg", "a/b.dmg", "a..b.dmg", ".hidden", "a b.dmg", "-rf"] {
            XCTAssertFalse(UpdateTrust.isSafeAssetName(bad), bad)
        }
    }

    func testDownloadURLMustBeThisRepoReleaseOnGitHub() {
        let ok = URL(string: "https://github.com/acme/kinhin/releases/download/v1/x.dmg")!
        XCTAssertTrue(UpdateTrust.isTrustedDownloadURL(ok, repo: "acme/kinhin"))
        let bad = [
            "http://github.com/acme/kinhin/releases/download/v1/x.dmg",
            "https://evil.com/acme/kinhin/releases/download/v1/x.dmg",
            "https://github.com.evil.com/acme/kinhin/releases/download/v1/x.dmg",
            "https://github.com/other/repo/releases/download/v1/x.dmg",
            "https://github.com/acme/kinhin/releases/download/../../x.dmg",
        ]
        for url in bad {
            XCTAssertFalse(UpdateTrust.isTrustedDownloadURL(URL(string: url)!, repo: "acme/kinhin"), url)
        }
    }

    func testTeamIDAndRequirement() {
        XCTAssertTrue(UpdateTrust.isValidTeamID("ABCDE12345"))
        XCTAssertFalse(UpdateTrust.isValidTeamID("abcde12345"))
        XCTAssertFalse(UpdateTrust.isValidTeamID("ABC\" or anchor apple"))
        XCTAssertEqual(
            UpdateTrust.requirement(teamID: "ABCDE12345"),
            "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }

    // MARK: - Release feed

    func testFetchRejectsInvalidRepo() async {
        let checker = UpdateChecker(repo: "a/../b", currentVersion: "0.1.0", trustedTeamID: nil)
        do {
            _ = try await checker.fetchLatestRelease()
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .invalidRepo("a/../b"))
        }
    }

    func testFetchRejectsDMGFromForeignHost() async {
        let body = Data(
            """
            {"tag_name":"v0.2.0","html_url":"https://github.com/acme/kinhin/releases/tag/v0.2.0","assets":[{"name":"\(dmgName)","browser_download_url":"https://evil.example/\(dmgName)"}]}
            """.utf8)
        StubProtocol.handler = { _ in (200, body, [:]) }
        do {
            _ = try await makeChecker(shell: FakeShell(), teamID: nil).fetchLatestRelease()
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .untrustedAsset(dmgName))
        }
    }

    func testFetchRejectsTraversalAssetName() async {
        let name = "../../evil-arm64.dmg"
        let body = Data(
            """
            {"tag_name":"v0.2.0","html_url":"https://github.com/acme/kinhin/releases/tag/v0.2.0","assets":[{"name":"\(name)","browser_download_url":"https://github.com/acme/kinhin/releases/download/v0.2.0/x-arm64.dmg"}]}
            """.utf8)
        StubProtocol.handler = { _ in (200, body, [:]) }
        do {
            _ = try await makeChecker(shell: FakeShell(), teamID: nil).fetchLatestRelease()
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .untrustedAsset(name))
        }
    }

    func testDownloadRejectsUnsafeNameInUpdateInfo() async {
        let info = UpdateInfo(
            tag: "v0.2.0", version: "0.2.0", dmgName: "../escape.dmg",
            dmgURL: URL(string: "https://github.com/acme/kinhin/releases/download/v0.2.0/x.dmg")!,
            releaseURL: URL(string: "https://github.com/acme/kinhin/releases/tag/v0.2.0")!,
            publishedAt: nil, notes: nil)
        do {
            _ = try await makeChecker(shell: FakeShell(), teamID: nil).downloadDMG(info)
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .untrustedAsset("../escape.dmg"))
        }
    }

    // MARK: - Signature

    func testDownloadVerifiesSignatureAgainstTeamID() async throws {
        stubDownload(payload: Data("dmg".utf8))
        let shell = FakeShell()
        let url = try await makeChecker(shell: shell, teamID: "ABCDE12345").downloadDMG(makeInfo())
        defer { try? FileManager.default.removeItem(at: url) }

        let call = try XCTUnwrap(shell.calls.first)
        XCTAssertEqual(call.first, "/usr/bin/codesign")
        XCTAssertTrue(call.contains("-R=" + UpdateTrust.requirement(teamID: "ABCDE12345")))
        XCTAssertEqual(call.last, url.path)
    }

    func testDownloadDeletesFileWhenSignatureCheckFails() async {
        stubDownload(payload: Data("dmg".utf8))
        let shell = FakeShell()
        shell.failAll = "code failed to satisfy specified code requirement(s)"
        do {
            _ = try await makeChecker(shell: shell, teamID: "ABCDE12345").downloadDMG(makeInfo())
            XCTFail("a wrongly signed DMG must throw")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .signatureInvalid(dmgName))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDMG().path))
    }

    func testDownloadSkipsSignatureCheckWithoutTeamID() async throws {
        stubDownload(payload: Data("dmg".utf8))
        let shell = FakeShell()
        let url = try await makeChecker(shell: shell, teamID: nil).downloadDMG(makeInfo())
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(shell.calls.isEmpty)
    }
}
