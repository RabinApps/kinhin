import Synchronization
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

    // MARK: - Send pipeline

    private func makeTransport(
        _ forge: ForgeID, _ authorization: ForgeTransport.Authorization, retries: Int = 0,
        baseDelay: TimeInterval = 1
    ) -> ForgeTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return ForgeTransport(
            session: URLSession(configuration: config), forge: forge, authorization: authorization,
            retries: retries, baseDelay: baseDelay)
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func testEachAuthorizationSchemeWritesItsForgeHeader() async throws {
        let schemes: [(ForgeTransport.Authorization, String, String)] = [
            (.bearer("t1"), "Authorization", "Bearer t1"),
            (.privateToken("t2"), "PRIVATE-TOKEN", "t2"),
            (.giteaToken("t3"), "Authorization", "token t3"),
        ]
        for (authorization, field, value) in schemes {
            StubProtocol.handler = { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: field), value)
                return (200, Data(), [:])
            }
            _ = try await makeTransport(.gitlab, authorization).send("GET", url("https://git.example.com/x"))
        }
        // The Basic scheme is base64(":<token>") — an empty user.
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic OjRuZXc=")
            return (200, Data(), [:])
        }
        _ = try await makeTransport(.azuredevops, .basicPassword("4new")).send("GET", url("https://dev.azure.com/x"))
    }

    func testCommonHeadersAreAppliedAndBodiesCarryJSONContentType() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/plain")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Kinhin/1.0")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (200, Data(), [:])
        }
        _ = try await makeTransport(.gitlab, .privateToken("t")).send(
            "POST", url("https://git.example.com/x"), body: Data("{}".utf8), accept: "text/plain")
    }

    func testStatusesMapToForgeAPIError() async {
        let transport = makeTransport(.buildkite, .bearer("t"))
        StubProtocol.handler = { _ in (401, Data(), [:]) }
        do {
            _ = try await transport.send("GET", url("https://api.buildkite.com/v2/x"))
            XCTFail("expected unauthorized")
        } catch let error as ForgeAPIError {
            XCTAssertEqual(error, .unauthorized(forge: .buildkite))
        } catch { XCTFail("unexpected \(error)") }

        StubProtocol.handler = { _ in (403, Data("nope".utf8), [:]) }
        do {
            _ = try await transport.send("GET", url("https://api.buildkite.com/v2/x"))
            XCTFail("expected forbidden")
        } catch let error as ForgeAPIError {
            XCTAssertEqual(error, .forbidden(forge: .buildkite, why: "nope"))
            XCTAssertTrue(error.localizedDescription.contains("member of the organization"))
        } catch { XCTFail("unexpected \(error)") }

        StubProtocol.handler = { _ in (404, Data(), [:]) }
        do {
            _ = try await transport.send("GET", url("https://api.buildkite.com/v2/missing"))
            XCTFail("expected notFound")
        } catch let error as ForgeAPIError {
            XCTAssertEqual(error, .notFound(forge: .buildkite, what: "/v2/missing"))
        } catch { XCTFail("unexpected \(error)") }

        StubProtocol.handler = { _ in (400, Data("bad".utf8), [:]) }
        do {
            _ = try await transport.send("GET", url("https://api.buildkite.com/v2/x"))
            XCTFail("expected http")
        } catch let error as ForgeAPIError {
            XCTAssertEqual(error, .http(forge: .buildkite, code: 400, body: "bad"))
        } catch { XCTFail("unexpected \(error)") }
    }

    func testTransientStatusesRetryAndThenSucceed() async throws {
        let attempts = Mutex<Int>(0)
        StubProtocol.handler = { _ in
            let n = attempts.withLock { n -> Int in
                n += 1; return n
            }
            return n < 3 ? (503, Data(), [:]) : (200, Data("{}".utf8), [:])
        }
        let transport = makeTransport(.gitea, .giteaToken("t"), retries: 3, baseDelay: 0.001)
        let (data, _) = try await transport.send("GET", url("https://gitea.example.com/api/v1/x"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{}")
        XCTAssertEqual(attempts.withLock { $0 }, 3)
    }

    func testTransientStatusesExhaustIntoTheirLastError() async {
        let attempts = Mutex<Int>(0)
        StubProtocol.handler = { _ in
            _ = attempts.withLock { $0 += 1 }
            return (500, Data("down".utf8), [:])
        }
        let transport = makeTransport(.gitea, .giteaToken("t"), retries: 1, baseDelay: 0.001)
        do {
            _ = try await transport.send("GET", url("https://gitea.example.com/api/v1/x"))
            XCTFail("expected the last 500 to surface")
        } catch let error as ForgeAPIError {
            XCTAssertEqual(error, .http(forge: .gitea, code: 500, body: "down"))
            XCTAssertEqual(attempts.withLock { $0 }, 2, "the first try plus one retry")
        } catch { XCTFail("unexpected \(error)") }
    }

    func testClassifyHookRunsBeforeTheDefaultMapping() async {
        let transport = makeTransport(.azuredevops, .basicPassword("t"))
        for (status, headers) in [(203, [String: String]()), (200, ["Content-Type": "text/html"])] {
            StubProtocol.handler = { _ in (status, Data("<html>Sign in</html>".utf8), headers) }
            do {
                _ = try await transport.send(
                    "GET", url("https://dev.azure.com/x"),
                    classify: { http, _ in
                        let html =
                            http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true
                        switch http.statusCode {
                        case 203: return .unauthorized(forge: .azuredevops)
                        case 200...299 where html: return .unauthorized(forge: .azuredevops)
                        default: return nil
                        }
                    })
                XCTFail("expected unauthorized for \(status)")
            } catch let error as ForgeAPIError {
                XCTAssertEqual(error, .unauthorized(forge: .azuredevops))
            } catch { XCTFail("unexpected \(error)") }
        }
    }

    func testForgeAPIErrorMessagesCarryTheForgeNameAndItsHint() {
        XCTAssertEqual(
            ForgeAPIError.unauthorized(forge: .gitlab).errorDescription,
            "GitLab rejected the access token (401): expired, revoked, or wrong instance. Fix: kinhin auth set NAME with a new token"
        )
        XCTAssertEqual(
            ForgeAPIError.forbidden(forge: .azuredevops, why: "no").errorDescription,
            "Azure DevOps forbidden (403): no. The token needs the Agent Pools (Read & manage) scope")
        XCTAssertEqual(
            ForgeAPIError.forbidden(forge: .gitea, why: "no").errorDescription, "Gitea forbidden (403): no")
        XCTAssertEqual(
            ForgeAPIError.decoding(forge: .bitbucket, what: "runners: bad JSON").errorDescription,
            "Could not decode Bitbucket response: runners: bad JSON")
    }
}
