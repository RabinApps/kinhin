import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
@testable import kinhin_app

/// Contract for `FakeUpdateChecker` as an `UpdateChecking`: the results it
/// scripts must be exactly what the real `UpdateChecker` derives from the
/// GitHub release feed — `.available` carrying the same tag, version, DMG
/// name and trusted URLs the parser builds, `.upToDate` for a feed at the
/// running version, and errors the controller shows verbatim (`notFound`,
/// `untrustedAsset`, `http`) that the fake can script identically. The real side is
/// an `UpdateChecker` over `StubProtocol` answering with release JSON; no
/// network is involved. `downloadDMG` is scripted bookkeeping — its
/// checksum/signature verification stays pinned by `UpdateCheckTests` and
/// `UpdateTrustTests` on the kit side.
final class FakeUpdateCheckerContractTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    /// The real checker the production conformance wraps, over a stub session.
    private func makeReal(currentVersion: String = "1.0.0") -> UpdateChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return UpdateChecker(
            repo: "acme/kinhin", currentVersion: currentVersion,
            session: URLSession(configuration: config), trustedTeamID: nil)
    }

    /// A canonical `releases/latest` body for the given tag and DMG URL.
    private func feed(tag: String, dmgURL: String) -> String {
        """
        {"tag_name":"\(tag)","name":"\(tag)","html_url":"https://github.com/acme/kinhin/releases/tag/\(tag)",
         "published_at":"2026-01-01T00:00:00Z","body":"release notes",
         "assets":[
           {"name":"kinhin-\(tag.dropFirst())-arm64.dmg","browser_download_url":"\(dmgURL)"},
           {"name":"checksums.txt",
            "browser_download_url":"https://github.com/acme/kinhin/releases/download/\(tag)/checksums.txt"}]}
        """
    }

    private func stub(_ status: Int, _ body: String) {
        StubProtocol.handler = { _ in (status, Data(body.utf8), [:]) }
    }

    /// The first error `op` throws (nil when it succeeds).
    private func firstError(_ op: () async throws -> Void) async -> Error? {
        do {
            try await op()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - A newer release

    func testANewerReleaseReadsAsTheAvailableResultTheFakeScripts() async throws {
        let body = feed(
            tag: "v1.2.3",
            dmgURL: "https://github.com/acme/kinhin/releases/download/v1.2.3/kinhin-1.2.3-arm64.dmg")
        let requested = Locked<String>("")
        StubProtocol.handler = { request in
            requested.withLock { $0 = request.url?.path ?? "" }
            return (200, Data(body.utf8), [:])
        }

        let real = try await makeReal().check()

        // What a test scripts the fake with, derived by hand from the feed.
        let scripted = UpdateInfo(
            tag: "v1.2.3", version: "1.2.3", dmgName: "kinhin-1.2.3-arm64.dmg",
            dmgURL: URL(string: "https://github.com/acme/kinhin/releases/download/v1.2.3/kinhin-1.2.3-arm64.dmg")!,
            checksumsURL: URL(string: "https://github.com/acme/kinhin/releases/download/v1.2.3/checksums.txt")!,
            releaseURL: URL(string: "https://github.com/acme/kinhin/releases/tag/v1.2.3")!,
            publishedAt: Date(timeIntervalSince1970: 1_767_225_600),
            notes: "release notes")
        XCTAssertEqual(
            real, .available(scripted),
            "the parser's field derivation is what every scripted UpdateInfo must match")

        let fake = FakeUpdateChecker()
        fake.checkResult = .success(.available(scripted))
        let fakeResult = try await fake.check()
        XCTAssertEqual(fakeResult, real, "a scripted answer is interchangeable with the real one")
        XCTAssertEqual(fake.checks, 1, "the fake counts checks like the controller's throttle expects")

        let path = requested.withLock { $0 }
        XCTAssertTrue(path.hasSuffix("/repos/acme/kinhin/releases/latest"), "the stable feed, not the list: \(path)")
    }

    // MARK: - Up to date

    func testAFeedAtTheRunningVersionReadsUpToDateOnBothSides() async throws {
        stub(
            200,
            feed(
                tag: "v1.0.0",
                dmgURL: "https://github.com/acme/kinhin/releases/download/v1.0.0/kinhin-1.0.0-arm64.dmg"))
        let real = try await makeReal().check()
        XCTAssertEqual(real, .upToDate, "an equal tag is not an update")

        let fake = FakeUpdateChecker()
        let fakeResult = try await fake.check()
        XCTAssertEqual(fakeResult, real, "the fake's default answer is the up-to-date result")
    }

    // MARK: - Failures

    func testRejectedFeedsThrowTheErrorsTheFakeScripts() async throws {
        // 404: no release at all.
        stub(404, "Not Found")
        let realNotFound = await firstError { _ = try await makeReal().check() }
        let fakeNotFound = await firstError {
            let fake = FakeUpdateChecker()
            fake.checkResult = .failure(UpdateCheckError.notFound("acme/kinhin"))
            _ = try await fake.check()
        }
        XCTAssertEqual(
            realNotFound as? UpdateCheckError, UpdateCheckError.notFound("acme/kinhin"),
            "the real checker turns the 404 into the error the controller logs")
        XCTAssertEqual(
            fakeNotFound as? UpdateCheckError, realNotFound as? UpdateCheckError,
            "the fake must be scriptable with the identical error")

        // A DMG served from anywhere but the release's own URL is refused.
        stub(200, feed(tag: "v1.2.3", dmgURL: "https://evil.example.com/kinhin-1.2.3-arm64.dmg"))
        let realUntrusted = await firstError { _ = try await makeReal().check() }
        let fakeUntrusted = await firstError {
            let fake = FakeUpdateChecker()
            fake.checkResult = .failure(UpdateCheckError.untrustedAsset("kinhin-1.2.3-arm64.dmg"))
            _ = try await fake.check()
        }
        XCTAssertEqual(
            realUntrusted as? UpdateCheckError, UpdateCheckError.untrustedAsset("kinhin-1.2.3-arm64.dmg"),
            "the parser refuses a foreign download host")
        XCTAssertEqual(
            fakeUntrusted as? UpdateCheckError, realUntrusted as? UpdateCheckError,
            "the fake must be scriptable with the identical refusal")

        // A failed release feed surfaces the status and body the controller
        // logs — the generic HTTP rejection every other status falls into.
        stub(500, "boom")
        let realHTTP = await firstError { _ = try await makeReal().check() }
        let fakeHTTP = await firstError {
            let fake = FakeUpdateChecker()
            fake.checkResult = .failure(UpdateCheckError.http(500, "boom"))
            _ = try await fake.check()
        }
        XCTAssertEqual(
            realHTTP as? UpdateCheckError, UpdateCheckError.http(500, "boom"),
            "a non-404 rejection carries the status code and the body verbatim")
        XCTAssertEqual(
            fakeHTTP as? UpdateCheckError, realHTTP as? UpdateCheckError,
            "the fake scripts the identical HTTP failure")
    }
}
