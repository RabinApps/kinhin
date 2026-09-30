import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class GiteaClientTests: XCTestCase {
    private func makeClient(instance: String = "https://gitea.example.com", scope: String = "acme/api") -> GiteaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return GiteaClient(
            credentials: GiteaCredentials(token: "gt", scope: scope, instance: instance),
            session: URLSession(configuration: config)
        )
    }

    func testListRepositoriesReadsWrappedResponse() async throws {
        StubProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.hasPrefix("/api/v1/repos/search"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token gt")
            let body = """
                {"ok":true,"data":[
                  {"full_name":"acme/api","private":false,"has_actions":true},
                  {"full_name":"acme/web","private":true,"has_actions":false}
                ]}
                """
            return (200, Data(body.utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let repos = try await makeClient().listRepositories()
        // Actions-enabled first, then alphabetical.
        XCTAssertEqual(repos.map(\.fullName), ["acme/api", "acme/web"])
        XCTAssertEqual(repos[1].isPrivate, true)
    }

    func testListRepositoriesReadsBareArrayResponse() async throws {
        StubProtocol.handler = { request in
            // A bare top-level JSON array (older Gitea) is not valid inside
            // the wrapped shape's {ok,data} — exercise the fallback path.
            let body = """
                [{"full_name":"acme/only","private":false,"has_actions":true}]
                """
            return (200, Data(body.utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let repos = try await makeClient().listRepositories()
        XCTAssertEqual(repos.map(\.fullName), ["acme/only"])
    }

    func testListRepositoriesSurfacesUnauthorized() async throws {
        StubProtocol.handler = { _ in (401, Data("no".utf8), [:]) }
        defer { StubProtocol.handler = nil }
        do {
            _ = try await makeClient().listRepositories()
            XCTFail("expected unauthorized")
        } catch let error as GiteaError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    // MARK: - Task queue (attribution)

    func testQueuedTasksParsesAttribution() async throws {
        StubProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix("/actions/tasks") ?? false)
            XCTAssertTrue(request.url?.query?.contains("status=waiting") ?? false)
            let body = """
                {"total_count":2,"entries":[
                  {"id":11,"name":"build","status":"waiting","repo_full_name":"acme/api"},
                  {"id":12,"title":"Nightly / test","status":"waiting",
                   "repository":{"full_name":"acme/web"}}
                ]}
                """
            return (200, Data(body.utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let tasks = try await makeClient(scope: "acme").queuedTasks()
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].repository, "acme/api")
        XCTAssertEqual(tasks[0].name, "build")
        XCTAssertEqual(tasks[1].repository, "acme/web", "nested attribution object is read")
        XCTAssertEqual(tasks[1].name, "Nightly / test", "title is the name fallback")
    }

    func testRunningTasksRequestsRunningStatus() async throws {
        StubProtocol.handler = { request in
            XCTAssertTrue(request.url?.query?.contains("status=running") ?? false)
            let body = """
                {"total_count":1,"entries":[{"id":9,"name":"deploy","status":"running",
                 "runner_name":"kinhin-abc123"}]}
                """
            return (200, Data(body.utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let tasks = try await makeClient(scope: "acme").runningTasks()
        XCTAssertEqual(tasks.first?.runnerName, "kinhin-abc123")
        XCTAssertEqual(tasks.count, 1)
    }

    func testTaskEntriesWithUnknownShapesStillCount() async throws {
        StubProtocol.handler = { _ in
            // Name/attribution fields absent (version variance): the entry
            // still decodes — attribution degrades, the count does not.
            let body = """
                {"total_count":2,"entries":[{"id":1},{"weird":true}]}
                """
            return (200, Data(body.utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let tasks = try await makeClient(scope: "acme").queuedTasks()
        XCTAssertEqual(tasks.count, 2)
        XCTAssertNil(tasks[0].repository)
    }

    func testTasksFallBackToCountPlaceholdersWhenEntriesAbsent() async throws {
        StubProtocol.handler = { _ in
            // Older Gitea: only total_count, no entries array.
            return (200, Data("{\"total_count\":3}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let tasks = try await makeClient(scope: "acme").queuedTasks()
        XCTAssertEqual(tasks.count, 3, "count-only shapes degrade to placeholders, not zero")
    }

    func testTasksSurfaceDecodingFailure() async throws {
        StubProtocol.handler = { _ in (200, Data("<html>not json</html>".utf8), [:]) }
        defer { StubProtocol.handler = nil }
        do {
            _ = try await makeClient(scope: "acme").queuedTasks()
            XCTFail("expected decoding error")
        } catch let error as GiteaError {
            guard case .decoding = error else { return XCTFail("wrong error: \(error)") }
        }
    }
}
