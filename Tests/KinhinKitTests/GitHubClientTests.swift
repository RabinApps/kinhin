import XCTest
@testable import KinhinKit

/// Intercepts URLSession traffic for deterministic tests.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data, headers) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

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
        let fullPage = (1...100).map { "{\"full_name\":\"acme/p\($0)\",\"private\":false,\"has_actions\":true}" }.joined(separator: ",")
        StubProtocol.handler = { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
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
        let client = GitHubClient(credentials: GitHubCredentials(token: "t", scope: "acme-corp"), session: {
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
            let body = "[{\"full_name\":\"me/app\",\"private\":true,\"has_actions\":true},{\"full_name\":\"corp/site\",\"private\":false,\"has_actions\":true}]"
            return (200, Data(body.utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let client = GitHubClient(credentials: GitHubCredentials(token: "t", scope: ""), session: {
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
            let page = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
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

    // MARK: org scope (one fleet, many repos)

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
            if path.hasPrefix("/orgs/acme/actions/runs") {
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
