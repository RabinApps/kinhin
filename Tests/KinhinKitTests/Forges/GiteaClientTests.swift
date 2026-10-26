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
        } catch let error as ForgeAPIError {
            XCTAssertEqual(error, .unauthorized(forge: .gitea))
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
        } catch let error as ForgeAPIError {
            guard case .decoding = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    // MARK: - Forgejo's task list (found live on Forgejo 11)

    /// Forgejo 11 answers `workflow_runs`, ignores `?status=`, lists finished runs too and names no runner.
    private var forgejoTasks: String {
        """
        {"workflow_runs":[
          {"id":3,"name":"slow","status":"running","display_title":"probe","run_number":3,"head_branch":"main"},
          {"id":2,"name":"prove","status":"success","display_title":"probe","run_number":2},
          {"id":1,"name":"prove","status":"failure","display_title":"hello","run_number":1}
        ],"total_count":3}
        """
    }

    func testTasksReadWorkflowRunsAndFilterByStatusClientSide() async throws {
        let body = forgejoTasks
        StubProtocol.handler = { _ in (200, Data(body.utf8), [:]) }
        defer { StubProtocol.handler = nil }
        let client = makeClient(scope: "e2e/demo")

        let running = try await client.runningTasks()
        XCTAssertEqual(running.map(\.name), ["slow"])
        XCTAssertEqual(running.first?.ref, "main")
        XCTAssertNil(running.first?.runnerName, "Forgejo reports no runner on a task")
        let queued = try await client.queuedTasks()
        XCTAssertEqual(queued, [], "finished runs are not demand")
    }

    func testActiveTaskCountSeesOnlyUnfinishedTasks() async throws {
        let body = LockedBox(forgejoTasks)
        StubProtocol.handler = { _ in (200, Data(body.value.utf8), [:]) }
        defer { StubProtocol.handler = nil }
        let client = makeClient(scope: "e2e/demo")
        let busy = try await client.activeTaskCount()
        XCTAssertEqual(busy, 1)

        body.value = "{\"workflow_runs\":[{\"id\":1,\"status\":\"success\"}],\"total_count\":1}"
        let idle = try await client.activeTaskCount()
        XCTAssertEqual(idle, 0)
        // A task whose status the server leaves out is treated as active.
        body.value = "{\"workflow_runs\":[{\"id\":1}],\"total_count\":1}"
        let unknown = try await client.activeTaskCount()
        XCTAssertEqual(unknown, 1)
    }

    func testRunningTasksReadsPastAFullPage() async throws {
        let requested = LockedBox<[String]>([])
        StubProtocol.handler = { request in
            let page =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value ?? "?"
            requested.value.append(page)
            let count = page == "1" ? 50 : 3
            let items = (0..<count).map { "{\"id\":\($0),\"status\":\"running\",\"runner_name\":\"r\(page)-\($0)\"}" }
            return (200, Data("{\"workflow_runs\":[\(items.joined(separator: ","))],\"total_count\":53}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let tasks = try await makeClient(scope: "e2e/demo").runningTasks()
        XCTAssertEqual(tasks.count, 53)
        XCTAssertEqual(requested.value, ["1", "2"])
    }

    func testActiveTaskCountPagesPastAFullPageOfFinishedTasks() async throws {
        let requested = LockedBox<[String]>([])
        StubProtocol.handler = { request in
            let page =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value ?? "?"
            requested.value.append(page)
            let finished = "{\"id\":1,\"status\":\"success\"}"
            let running = "{\"id\":2,\"status\":\"running\"}"
            let items = page == "1" ? Array(repeating: finished, count: 50) : [running]
            return (200, Data("{\"workflow_runs\":[\(items.joined(separator: ","))],\"total_count\":51}".utf8), [:])
        }
        defer { StubProtocol.handler = nil }
        let count = try await makeClient(scope: "e2e/demo").activeTaskCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(requested.value, ["1", "2"])
    }
}

/// A mutable value a `@Sendable` stub handler can share with its test.
private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
