import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class GitHubClientTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func makeClient() -> GitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return GitHubClient(
            credentials: GitHubCredentials(token: "test-token", scope: "acme/widgets"),
            session: URLSession(configuration: config)
        )
    }

    func testListRepositoriesPaginatesAndSortsActionsFirst() async throws {
        // A full 100-item page keeps pagination going; the short page ends it.
        // Parse the page per request — a cached "page 1" branch would feed
        // the full page forever and hang pagination.
        let fullPage = (1...100).map { "{\"full_name\":\"acme/p\($0)\",\"private\":false,\"has_actions\":true}" }
            .joined(separator: ",")
        StubProtocol.handler = { request in
            let page =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "page" })?.value ?? "1"
            if page == "1" {
                return (200, Data("[\(fullPage)]".utf8), [:])
            }
            return (200, Data("[{\"full_name\":\"acme/last\",\"private\":false,\"has_actions\":true}]".utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let repos = try await makeClient().listRepositories()
        XCTAssertEqual(repos.count, 101, "100 from the full page + 1 from the short page")
        XCTAssertTrue(repos.contains { $0.fullName == "acme/last" })
        XCTAssertTrue(repos.contains { $0.fullName == "acme/p1" })
    }

    func testListRepositoriesOrgScopeHitsOrgEndpoint() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/orgs/acme-corp/repos")
            let body = "[{\"full_name\":\"acme-corp/site\",\"private\":false,\"has_actions\":true}]"
            return (200, Data(body.utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let client = GitHubClient(
            credentials: GitHubCredentials(token: "t", scope: "acme-corp"),
            session: {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [StubProtocol.self]
                return URLSession(configuration: config)
            }())
        let repos = try await client.listRepositories()
        XCTAssertEqual(repos.map(\.fullName), ["acme-corp/site"])
    }

    func testListRepositoriesWithNoScopeListsTheTokenOwnersRepos() async throws {
        // Onboarding has no scope yet: it must list what the token can see,
        // never a made-up "placeholder" user's repos.
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/user/repos")
            XCTAssertTrue(request.url!.query!.contains("affiliation=owner,collaborator,organization_member"))
            let body =
                "[{\"full_name\":\"me/app\",\"private\":true,\"has_actions\":true},{\"full_name\":\"corp/site\",\"private\":false,\"has_actions\":true}]"
            return (200, Data(body.utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let client = GitHubClient(
            credentials: GitHubCredentials(token: "t", scope: ""),
            session: {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [StubProtocol.self]
                return URLSession(configuration: config)
            }())
        let repos = try await client.listRepositories()
        XCTAssertEqual(Set(repos.map(\.fullName)), ["me/app", "corp/site"])
    }

    func testFetchRegistrationToken() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/acme/widgets/actions/runners/registration-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let body = """
                {"token":"FRank123","expires_at":"2026-09-21T12:00:00Z"}
                """
            return (201, Data(body.utf8), [:])
        }
        let token = try await makeClient().fetchRegistrationToken()
        XCTAssertEqual(token.token, "FRank123")
    }

    func testListRunnersPagination() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let page =
                Int(
                    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "page" })?.value ?? "1") ?? 1
            XCTAssertEqual(path, "/repos/acme/widgets/actions/runners")
            if page == 1 {
                let body = """
                    {"total_count":2,"runners":[
                      {"id":1,"name":"kinhin-1","status":"online","busy":true,"labels":[{"name":"self-hosted"}]},
                      {"id":2,"name":"kinhin-2","status":"online","busy":false,"labels":[]}
                    ]}
                    """
                return (200, Data(body.utf8), [:])
            }
            return (200, Data("{\"total_count\":2,\"runners\":[]}".utf8), [:])
        }
        let runners = try await makeClient().listRunners()
        XCTAssertEqual(runners.count, 2)
        XCTAssertTrue(runners[0].busy)
    }

    // MARK: - org scope (one fleet, many repos)

    func makeOrgClient() -> GitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return GitHubClient(
            credentials: GitHubCredentials(token: "test-token", scope: "acme"),
            session: URLSession(configuration: config)
        )
    }

    func testOrgScopeRoutesToOrgEndpoints() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/orgs/acme/actions/runners/registration-token" {
                return (201, Data("{\"token\":\"T\",\"expires_at\":\"2026-09-21T12:00:00Z\"}".utf8), [:])
            }
            if path.hasPrefix("/orgs/acme/actions/runners") {
                return (200, Data("{\"total_count\":0,\"runners\":[]}".utf8), [:])
            }
            if path == "/orgs/acme/repos" {
                return (200, Data("[{\"full_name\":\"acme/widgets\"}]".utf8), [:])
            }
            if path == "/repos/acme/widgets/actions/runs" {
                return (200, Data("{\"total_count\":0,\"workflow_runs\":[]}".utf8), [:])
            }
            XCTFail("unexpected path: \(path)")
            return (404, Data(), [:])
        }
        let client = makeOrgClient()
        _ = try await client.fetchRegistrationToken()
        _ = try await client.listRunners()
        let jobs = try await client.queuedJobs(matching: ["self-hosted"])
        XCTAssertTrue(jobs.isEmpty)
    }

    func testOrgConfigureURLIsOrganizationsPath() {
        XCTAssertEqual(makeOrgClient().configureURL, "https://github.com/organizations/acme")
    }

    // MARK: - org scope reads runs per repository

    func testOrgScopeReadsPerRepoAndAttributes() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/orgs/acme/actions/runs" {
                XCTFail("org runs endpoint must never be called")
                return (404, Data("{\"message\":\"Not Found\"}".utf8), [:])
            }
            if path == "/orgs/acme/repos" {
                return (200, Data("[{\"full_name\":\"acme/widgets\"},{\"full_name\":\"acme/api\"}]".utf8), [:])
            }
            if path == "/repos/acme/widgets/actions/runs" {
                return (200, Data("{\"total_count\":1,\"workflow_runs\":[{\"id\":1}]}".utf8), [:])
            }
            if path == "/repos/acme/widgets/actions/runs/1/jobs" {
                return (
                    200,
                    Data(
                        """
                        {"jobs":[{"id":11,"run_id":1,"name":"build","status":"queued","labels":["kinhin"]}]}
                        """.utf8),
                    [:]
                )
            }
            if path == "/repos/acme/api/actions/runs" {
                return (200, Data("{\"total_count\":0,\"workflow_runs\":[]}".utf8), [:])
            }
            XCTFail("unexpected path: \(path)")
            return (404, Data(), [:])
        }
        defer { StubProtocol.handler = nil }

        let jobs = try await makeOrgClient().queuedJobs(matching: ["kinhin"])
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.repository, "acme/widgets", "per-repo reads must attribute the scoped repo")
    }

    func testOrgScopeNeverRequestsOrgRunsEndpointEvenIfItWouldAnswer() async throws {
        let orgRunsCalls = Mutex(0)
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/orgs/acme/actions/runs" {
                orgRunsCalls.withLock { $0 += 1 }
                return (200, Data("{\"total_count\":0,\"workflow_runs\":[]}".utf8), [:])
            }
            if path == "/orgs/acme/repos" {
                return (200, Data("[{\"full_name\":\"acme/widgets\"}]".utf8), [:])
            }
            if path == "/repos/acme/widgets/actions/runs" {
                return (200, Data("{\"total_count\":0,\"workflow_runs\":[]}".utf8), [:])
            }
            XCTFail("unexpected path: \(path)")
            return (404, Data(), [:])
        }
        defer { StubProtocol.handler = nil }

        let client = makeOrgClient()
        _ = try await client.queuedJobs(matching: ["self-hosted"])
        _ = try await client.runningJobs(matching: ["self-hosted"])
        XCTAssertEqual(orgRunsCalls.withLock { $0 }, 0)
    }

    func testOrgRunsFallbackUsesUserReposWhenOrgListIsUnreadable() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/orgs/acme/repos" {
                return (404, Data("{\"message\":\"Not Found\"}".utf8), [:])
            }
            if path == "/user/repos" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.query ?? ""
                XCTAssertTrue(query.contains("affiliation=owner,collaborator,organization_member"), query)
                return (
                    200,
                    Data("[{\"full_name\":\"acme/widgets\"},{\"full_name\":\"other/thing\"}]".utf8), [:]
                )
            }
            if path == "/repos/acme/widgets/actions/runs" {
                return (200, Data("{\"total_count\":0,\"workflow_runs\":[]}".utf8), [:])
            }
            XCTFail("unexpected path: \(path)")
            return (404, Data(), [:])
        }
        defer { StubProtocol.handler = nil }

        let jobs = try await makeOrgClient().queuedJobs(matching: ["kinhin"])
        XCTAssertTrue(jobs.isEmpty)
    }

    func testOrgRunsFallbackSkipsUnreadableRepos() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/orgs/acme/repos" {
                return (200, Data("[{\"full_name\":\"acme/open\"},{\"full_name\":\"acme/locked\"}]".utf8), [:])
            }
            if path == "/repos/acme/open/actions/runs" {
                return (200, Data("{\"total_count\":0,\"workflow_runs\":[]}".utf8), [:])
            }
            if path == "/repos/acme/locked/actions/runs" {
                return (404, Data("{\"message\":\"Not Found\"}".utf8), [:])
            }
            XCTFail("unexpected path: \(path)")
            return (404, Data(), [:])
        }
        defer { StubProtocol.handler = nil }

        let jobs = try await makeOrgClient().queuedJobs(matching: ["kinhin"])
        XCTAssertTrue(jobs.isEmpty, "one unreadable repository must not fail the whole read")
    }

    func testOrgRuns404ErrorMessagePointsAtRepositoryAccess() {
        let orgError = GitHubError.notFound("/orgs/acme/actions/runs")
        let orgMessage = orgError.errorDescription ?? ""
        XCTAssertTrue(orgMessage.contains("per repository"), orgMessage)
        XCTAssertTrue(orgMessage.contains("Actions: Read-only"), orgMessage)

        // Non-org runs paths keep the generic message.
        let repoError = GitHubError.notFound("/repos/acme/widgets/actions/runs")
        XCTAssertTrue(repoError.errorDescription?.contains("Does the repo exist") ?? false)
    }

    func testOrgRunsFallbackFailsWhenNoRepositoryIsReadable() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/orgs/acme/repos" {
                return (404, Data("{\"message\":\"Not Found\"}".utf8), [:])
            }
            if path == "/user/repos" {
                return (200, Data("[{\"full_name\":\"acme/widgets\"}]".utf8), [:])
            }
            if path == "/repos/acme/widgets/actions/runs" {
                return (404, Data("{\"message\":\"Not Found\"}".utf8), [:])
            }
            XCTFail("unexpected path: \(path)")
            return (404, Data(), [:])
        }
        defer { StubProtocol.handler = nil }

        do {
            _ = try await makeOrgClient().queuedJobs(matching: ["kinhin"])
            XCTFail("should throw — an empty queue must not hide an unreadable token")
        } catch let error as GitHubError {
            guard case .notFound(let what) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertTrue(what.contains("/*/actions/runs"), what)
            XCTAssertTrue(
                error.errorDescription?.contains("Actions: Read-only") ?? false,
                error.errorDescription ?? "")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testInvalidScopeSpecThrows() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GitHubClient(
            credentials: GitHubCredentials(token: "t", scope: "a/b/c"),
            session: URLSession(configuration: config)
        )
        do {
            _ = try await client.fetchRegistrationToken()
            XCTFail("should throw")
        } catch let error as GitHubError {
            guard case .http(0, let why) = error else { return XCTFail("wrong error") }
            XCTAssertTrue(why.contains("invalid scope"), why)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testUnauthorizedSurfacesCleanError() async {
        StubProtocol.handler = { _ in (401, Data("bad credentials".utf8), [:]) }
        do {
            _ = try await makeClient().fetchRegistrationToken()
            XCTFail("should throw")
        } catch let error as GitHubError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRateLimitParsed() async {
        StubProtocol.handler = { _ in
            (
                403,
                Data("rate limit".utf8),
                ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "9999999999"]
            )
        }
        do {
            _ = try await makeClient().listRunners()
            XCTFail("should throw")
        } catch let error as GitHubError {
            guard case .rateLimited = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testQueuedJobsLabelFiltering() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/repos/acme/widgets/actions/runs" {
                let body = """
                    {"total_count":2,"workflow_runs":[{"id":101},{"id":102}]}
                    """
                return (200, Data(body.utf8), [:])
            }
            if path.hasSuffix("/jobs") {
                let runID = Int(request.url!.path.split(separator: "/").dropLast(1).last ?? "0") ?? 0
                let jobs: String
                if runID == 101 {
                    // matches: has all fleet labels + extra
                    jobs = """
                        {"jobs":[{"id":1,"run_id":101,"name":"build","status":"queued","labels":["ubuntu-latest","macos","kinhin"]}]}
                        """
                } else {
                    // does not match: missing "kinhin"
                    jobs = """
                        {"jobs":[{"id":2,"run_id":102,"name":"test","status":"queued","labels":["macos"]}]}
                        """
                }
                return (200, Data(jobs.utf8), [:])
            }
            return (404, Data(), [:])
        }
        let jobs = try await makeClient().queuedJobs(matching: ["macos", "kinhin"])
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.jobID, 1)
    }
}
