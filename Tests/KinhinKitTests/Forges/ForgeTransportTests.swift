import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The https rule for self-hosted instances, the redirect guard, and the
/// per-account `allow_insecure_http` opt-in.
final class ForgeTransportTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: - Scheme rule

    func testHTTPSIsAlwaysPermitted() {
        XCTAssertTrue(ForgeHTTP.permitsScheme(of: url("https://git.example.com"), allowInsecureHTTP: false))
    }

    func testHTTPNeedsTheFlagUnlessLoopback() {
        let lan = url("http://gitea.lan:3000")
        XCTAssertFalse(ForgeHTTP.permitsScheme(of: lan, allowInsecureHTTP: false))
        XCTAssertTrue(ForgeHTTP.permitsScheme(of: lan, allowInsecureHTTP: true))
        for loopback in ["http://localhost:3000", "http://127.0.0.1:3000", "http://[::1]:3000", "http://ci.localhost"] {
            XCTAssertTrue(ForgeHTTP.permitsScheme(of: url(loopback), allowInsecureHTTP: false), loopback)
        }
        XCTAssertFalse(ForgeHTTP.permitsScheme(of: url("http://localhost.evil.example"), allowInsecureHTTP: false))
    }

    func testOtherSchemesAreNeverPermitted() {
        for scheme in ["ftp://host", "file:///etc/passwd", "ssh://host"] {
            XCTAssertFalse(ForgeHTTP.permitsScheme(of: url(scheme), allowInsecureHTTP: true), scheme)
        }
    }

    func testEachForgeValidatesInstancesWithTheSameRule() throws {
        XCTAssertThrowsError(try GiteaCredentials.validate(instance: "http://gitea.lan"))
        XCTAssertNoThrow(try GiteaCredentials.validate(instance: "http://gitea.lan", allowInsecureHTTP: true))
        XCTAssertThrowsError(try GitLabCredentials.validate(instance: "http://gitlab.lan"))
        XCTAssertNoThrow(try GitLabCredentials.validate(instance: "http://gitlab.lan", allowInsecureHTTP: true))
        XCTAssertThrowsError(try AzureDevOpsCredentials.validate(instance: "http://tfs.lan/tfs/DefaultCollection"))
        XCTAssertNoThrow(
            try AzureDevOpsCredentials.validate(
                instance: "http://tfs.lan/tfs/DefaultCollection", allowInsecureHTTP: true))
        XCTAssertNoThrow(try GiteaCredentials.validate(instance: "http://localhost:3000"))
    }

    // MARK: - Redirects

    func testRedirectsMustStayOnTheSameHostAndNeverDowngrade() {
        let origin = url("https://git.example.com/api/v1/repos")
        XCTAssertTrue(ForgeHTTP.allowsRedirect(from: origin, to: url("https://git.example.com/api/v1/repositories/7")))
        XCTAssertTrue(ForgeHTTP.allowsRedirect(from: origin, to: url("https://GIT.example.com/x")), "host case")
        XCTAssertFalse(ForgeHTTP.allowsRedirect(from: origin, to: url("https://evil.example/x")))
        XCTAssertFalse(ForgeHTTP.allowsRedirect(from: origin, to: url("https://git.example.com.evil.example/x")))
        XCTAssertFalse(ForgeHTTP.allowsRedirect(from: origin, to: url("http://git.example.com/x")), "downgrade")
        XCTAssertFalse(ForgeHTTP.allowsRedirect(from: origin, to: nil))
        XCTAssertFalse(ForgeHTTP.allowsRedirect(from: nil, to: origin))
    }

    func testPlainHTTPInstanceMayUpgradeToHTTPSOnTheSameHost() {
        let origin = url("http://gitea.lan/api")
        XCTAssertTrue(ForgeHTTP.allowsRedirect(from: origin, to: url("https://gitea.lan/api")))
        XCTAssertTrue(ForgeHTTP.allowsRedirect(from: origin, to: url("http://gitea.lan/other")))
        XCTAssertFalse(ForgeHTTP.allowsRedirect(from: origin, to: url("http://other.lan/api")))
    }

    // MARK: - Pagination links

    func testBuildkitePageLinksMustStayOnTheAPIHost() {
        XCTAssertTrue(BuildkiteClient.isTrustedPageLink(url("https://api.buildkite.com/v2/x?page=2")))
        for bad in [
            "http://api.buildkite.com/v2/x", "https://api.buildkite.com.evil.example/v2/x",
            "https://evil.example/v2/x", "https://api.buildkite.com@evil.example/v2/x",
            "https://api.buildkite.com:8443/v2/x",
        ] {
            XCTAssertFalse(BuildkiteClient.isTrustedPageLink(url(bad)), bad)
        }
    }

    func testBitbucketComparesParsedHostsNotStringPrefixes() throws {
        let client = BitbucketClient(credentials: BitbucketCredentials(token: "t", scope: "acme"))
        XCTAssertNoThrow(try client.url("https://api.bitbucket.org/2.0/repositories/acme?page=2"))
        for bad in [
            "https://api.bitbucket.org.evil.example/2.0/x", "http://api.bitbucket.org/2.0/x",
            "https://evil.example/https://api.bitbucket.org/2.0/x",
        ] {
            XCTAssertThrowsError(try client.url(bad), bad) { error in
                XCTAssertEqual(error as? BitbucketError, .untrustedPageLink(bad))
            }
        }
    }

    // MARK: - GitHub scope

    func testGitHubScopeSegmentsCannotReshapeTheRequestPath() {
        for good in ["acme", "my-org", "repo.name", "a_b"] {
            XCTAssertTrue(GitHubClient.isValidScopeSegment(Substring(good)), good)
        }
        for bad in ["", ".", "..", "a?x=1", "a#f", "a b", "a%2f", "né"] {
            XCTAssertFalse(GitHubClient.isValidScopeSegment(Substring(bad)), bad)
        }
    }

    func testGitHubRequestRejectsATraversalScope() {
        let client = GitHubClient(credentials: GitHubCredentials(token: "t", scope: "acme/.."))
        XCTAssertThrowsError(try client.request(method: "GET", path: "/repos/x"))
    }
}
