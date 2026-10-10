import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class BitbucketClientTests: XCTestCase {
    private func makeClient(scope: String = "acme") -> BitbucketClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return BitbucketClient(
            credentials: BitbucketCredentials(token: "tkn", scope: scope),
            session: URLSession(configuration: config))
    }

    private static func json(_ body: String) -> (Int, Data, [String: String]) {
        (200, Data(body.utf8), ["Content-Type": "application/json; charset=utf-8"])
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Credentials and scope

    func testScopeValidationAndParts() {
        XCTAssertTrue(BitbucketCredentials.isValidScope("acme"))
        XCTAssertTrue(BitbucketCredentials.isValidScope("acme/api-server"))
        XCTAssertFalse(BitbucketCredentials.isValidScope(""))
        XCTAssertFalse(BitbucketCredentials.isValidScope("acme/"))
        XCTAssertFalse(BitbucketCredentials.isValidScope("ACME/api"))
        let credentials = BitbucketCredentials(token: "t", scope: "acme/api-server")
        XCTAssertEqual(credentials.workspace, "acme")
        XCTAssertEqual(credentials.repository, "api-server")
        XCTAssertEqual(BitbucketCredentials(token: "t", scope: "acme").repository, "")
    }

    func testWorkspaceScopeEndPointsAndRepoScopeNarrowing() {
        let workspace = BitbucketScope(credentials: BitbucketCredentials(token: "t", scope: "acme"))
        XCTAssertEqual(workspace.runnerPath, "/2.0/workspaces/acme/pipelines-config/runners")
        XCTAssertEqual(workspace.description, "acme")
        let repo = BitbucketScope(credentials: BitbucketCredentials(token: "t", scope: "acme/api-server"))
        XCTAssertEqual(repo.runnerPath, "/2.0/repositories/acme/api-server/pipelines-config/runners")
        XCTAssertEqual(repo.description, "acme/api-server")
    }

    func testSendsTheTokenAsABearerHeader() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tkn")
            return Self.json(#"{"values": [], "next": null}"#)
        }
        let runners = try await makeClient().listRunners(scope: .workspace("acme"))
        XCTAssertEqual(runners, [])
    }

    /// The request's path, trailing slashes kept (which `URL.path` drops).
    private static func path(_ request: URLRequest) -> String {
        guard var components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return ""
        }
        components.query = nil
        components.scheme = nil
        components.host = nil
        return components.percentEncodedPath
    }

    // MARK: - Runners

    func testListsRunnersWithTheirState() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(Self.path(request), "/2.0/workspaces/acme/pipelines-config/runners")
            return Self.json(
                #"""
                {"values": [
                  {"uuid": "{r1}", "name": "kinhin-1-r1", "labels": ["self.hosted", "macos"],
                   "state": {"status": "ONLINE"}},
                  {"uuid": "{r2}", "name": "kinhin-1-r2", "state": {"status": "OFFLINE"}}
                ]}
                """#
            )
        }
        let runners = try await makeClient().listRunners(scope: .workspace("acme"))
        XCTAssertEqual(runners.map(\.uuid), ["{r1}", "{r2}"])
        XCTAssertEqual(runners.map(\.isOnline), [true, false])
        XCTAssertEqual(runners.first?.labels, ["self.hosted", "macos"])
    }

    func testCreateRunnerCapturesTheSingleShowingOAuthSecret() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(Self.path(request), "/2.0/workspaces/acme/pipelines-config/runners")
            return Self.json(
                #"""
                {"uuid": "{r1}", "name": "kinhin-1-r1", "labels": ["self.hosted"],
                 "state": {"status": "UNREGISTERED"},
                 "oauth_client": {"id": "cli-9", "secret": "shh",
                                  "token_endpoint": "https://bitbucket.org/site/oauth2/access_token"}}
                """#
            )
        }
        let runner = try await makeClient().createRunner(
            scope: .workspace("acme"), name: "kinhin-1-r1", labels: ["self.hosted"])
        XCTAssertEqual(runner.oauthClient?.id, "cli-9")
        XCTAssertEqual(runner.oauthClient?.secret, "shh")
    }

    func testCreateRunnerWithoutASecretIsNamed() async {
        StubProtocol.handler = { _ in
            Self.json(#"{"uuid": "{r1}", "name": "kinhin-1-r1", "state": {"status": "UNREGISTERED"}}"#)
        }
        do {
            _ = try await makeClient().createRunner(scope: .workspace("acme"), name: "kinhin-1-r1", labels: [])
            XCTFail("expected missingOAuthClientSecret")
        } catch let error as BitbucketError {
            XCTAssertEqual(error, .missingOAuthClientSecret("kinhin-1-r1"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testDeletingAGoneRunnerSucceeds() async throws {
        let calls = Mutex<[String]>([])
        StubProtocol.handler = { request in
            calls.withLock { $0.append("\(request.httpMethod ?? "") \(Self.path(request))") }
            return (404, Data(), [:])
        }
        try await makeClient().deleteRunner(scope: .workspace("acme"), uuid: "{r1}")
        XCTAssertEqual(
            calls.withLock { $0 },
            ["DELETE /2.0/workspaces/acme/pipelines-config/runners/%7Br1%7D"],
            "the UUID's braces are percent-encoded on the wire, as Bitbucket expects")
    }

    // MARK: - Scope check

    func testVerifyScopeAcceptsAWorkspaceAndRejectsAMissingOne() async throws {
        StubProtocol.handler = { request in
            Self.path(request) == "/2.0/workspaces/acme"
                ? Self.json(#"{"uuid": "{w}", "name": "acme"}"#) : (404, Data(), [:])
        }
        try await makeClient().verifyScope()
        do {
            try await makeClient(scope: "missing").verifyScope()
            XCTFail("expected scopeNotFound")
        } catch let error as BitbucketError {
            XCTAssertEqual(error, .scopeNotFound("workspace missing"))
        }
    }

    // MARK: - Demand

    /// Demand polling: the repo's newest pipelines, active ones followed to
    /// their steps. Bitbucket's step payload carries no `runs_on` yet (the
    /// runner matches on the forge side), so kinhin treats every step of an
    /// active pipeline as demand for its runners.
    func testDemandReadsStepsOfActivePipelines() async throws {
        StubProtocol.handler = { request in
            let path = Self.path(request)
            if path == "/2.0/repositories/acme/api-server/pipelines/" {
                return Self.json(
                    #"""
                    {"values": [
                      {"uuid": "{p1}", "repository": {"full_name": "acme/api-server"},
                       "state": {"name": "IN_PROGRESS"}},
                      {"uuid": "{p2}", "repository": {"full_name": "acme/api-server"},
                       "state": {"name": "COMPLETED"}}
                    ], "next": null}
                    """#
                )
            }
            if path == "/2.0/repositories/acme/api-server/pipelines/%7Bp1%7D/steps" {
                return Self.json(
                    #"""
                    {"values": [
                      {"uuid": "{s1}", "state": {"name": "PENDING"}},
                      {"uuid": "{s2}", "state": {"name": "IN_PROGRESS"}}
                    ], "next": null}
                    """#
                )
            }
            XCTFail("unexpected request \(path)")
            return (404, Data(), [:])
        }
        let scope = BitbucketScope(credentials: BitbucketCredentials(token: "t", scope: "acme/api-server"))
        let jobs = try await makeClient().activeJobs(scope: scope, repos: ["acme/api-server"])
        XCTAssertEqual(jobs.map(\.name), ["{s1}", "{s2}"], "a step without a name falls back to its uuid")
        XCTAssertEqual(jobs.map(\.stateName), ["PENDING", "IN_PROGRESS"])
        XCTAssertEqual(jobs.map(\.repository), ["acme/api-server", "acme/api-server"])
        XCTAssertEqual(jobs.map(\.isQueued), [true, false])
        XCTAssertEqual(jobs.map(\.isRunning), [false, true])
    }

    func testWorkspaceScopePollsOnlyTheReposItIsGiven() async throws {
        let requested = Mutex<[String]>([])
        StubProtocol.handler = { request in
            let path = Self.path(request)
            requested.withLock { $0.append(path) }
            return path.hasSuffix("/pipelines/") ? Self.json(#"{"values": [], "next": null}"#) : (404, Data(), [:])
        }
        _ = try await makeClient().activeJobs(scope: .workspace("acme"), repos: ["acme/one", "acme/two"])
        XCTAssertEqual(
            requested.withLock { $0 }.filter { $0.hasSuffix("/pipelines/") },
            ["/2.0/repositories/acme/one/pipelines/", "/2.0/repositories/acme/two/pipelines/"])
    }

    func testPaginationFollowsNextLinks() async throws {
        let pages = Mutex<Int>(0)
        StubProtocol.handler = { _ in
            let page = pages.withLock {
                $0 += 1; return $0
            }
            return page == 1
                ? Self.json(
                    #"{"values": [{"uuid": "{r1}", "name": "a", "state": {"status": "ONLINE"}}], "next": "#
                        + #""https://api.bitbucket.org/2.0/workspaces/acme/pipelines-config/runners?page=2"}"#)
                : Self.json(#"{"values": [{"uuid": "{r2}", "name": "b", "state": {"status": "ONLINE"}}]}"#)
        }
        let runners = try await makeClient().listRunners(scope: .workspace("acme"))
        XCTAssertEqual(runners.map(\.uuid), ["{r1}", "{r2}"])
        XCTAssertEqual(pages.withLock { $0 }, 2)
    }

    /// A repository list in the shape Bitbucket Cloud returns: `updated_on` is an ISO-8601 string with microseconds
    /// and an offset. Decoded as a `Date` it threw, and every workspace-scope poll failed with it.
    func testActiveRepositoriesDecodeTheRealRepositoryPayload() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(Self.path(request), "/2.0/repositories/acme")
            return Self.json(
                #"""
                {
                  "pagelen": 100,
                  "size": 2,
                  "page": 1,
                  "values": [
                    {
                      "type": "repository",
                      "full_name": "acme/api",
                      "name": "api",
                      "slug": "api",
                      "uuid": "{2c3a8b1e-8f2c-4f4e-9d52-0c0f0b4b9c11}",
                      "is_private": true,
                      "scm": "git",
                      "created_on": "2023-11-02T09:15:03.123456+00:00",
                      "updated_on": "2026-02-14T18:42:09.987654+00:00",
                      "size": 18874368,
                      "language": "swift",
                      "mainbranch": {"name": "main", "type": "branch"},
                      "workspace": {"slug": "acme", "type": "workspace", "uuid": "{a1}"},
                      "links": {"self": {"href": "https://api.bitbucket.org/2.0/repositories/acme/api"}}
                    },
                    {
                      "type": "repository",
                      "full_name": "acme/web",
                      "slug": "web",
                      "uuid": "{9d2c}",
                      "updated_on": "2025-12-01T00:00:00+00:00"
                    }
                  ]
                }
                """#)
        }
        let repos = try await makeClient().activeRepositories(scope: .workspace("acme"))
        XCTAssertEqual(repos, ["acme/api", "acme/web"])
    }

    // MARK: - Errors

    func testTransienceAndCategory() {
        XCTAssertTrue(ForgeTransport.isTransient(ForgeAPIError.http(forge: .bitbucket, code: 503, body: "")))
        XCTAssertFalse(ForgeTransport.isTransient(ForgeAPIError.http(forge: .bitbucket, code: 400, body: "")))
        XCTAssertFalse(ForgeTransport.isTransient(ForgeAPIError.unauthorized(forge: .bitbucket)))
        XCTAssertEqual(ErrorCategory(ForgeAPIError.unauthorized(forge: .bitbucket)), .auth)
    }
}
