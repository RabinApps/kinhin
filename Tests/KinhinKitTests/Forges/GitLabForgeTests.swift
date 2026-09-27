import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The GitLab forge against a small simulated GitLab (runners, jobs) behind
/// `StubProtocol`: its mapping onto the Forge surface, and the engine driving
/// one instance through create → online → busy → self-delete → VM deleted.
final class GitLabForgeTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func makeForge(
        server: FakeGitLabServer, scope: GitLabScope = .project(id: 7, path: "acme/api"), labels: [String] = ["macos"]
    ) -> GitLabForge {
        StubProtocol.handler = { server.handle($0) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GitLabClient(
            credentials: GitLabCredentials(token: "glpat", scope: "acme/api"),
            session: URLSession(configuration: config))
        return GitLabForge(
            credentials: .gitlab(token: "glpat", scope: "acme/api", instance: GitLabCredentials.defaultInstance),
            labels: labels, client: client, scope: scope, runnerListTTL: 0)
    }

    // MARK: Forge surface

    func testIdentityAndBehavior() {
        let forge = makeForge(server: FakeGitLabServer())
        XCTAssertEqual(forge.id, .gitlab)
        XCTAssertEqual(forge.account, "gitlab")
        XCTAssertEqual(forge.registration, .perRunner)
        XCTAssertEqual(forge.exitSemantics, .deregisters)
        XCTAssertEqual(forge.registrationURL(), "https://gitlab.com")
        XCTAssertFalse(forge.attributesByRepo, "a project scope has nothing to break down")
        XCTAssertTrue(makeForge(server: FakeGitLabServer(), scope: .group(id: 3, path: "acme")).attributesByRepo)
    }

    func testRegistrationCreatesOneRunnerPerNameWithPoolTags() async throws {
        let server = FakeGitLabServer()
        let forge = makeForge(server: server)
        let tokens = try await forge.registrationTokens(
            runnerNames: ["kinhin-1-r1", "kinhin-1-r2"], labels: ["macos", "kinhin-host"])
        XCTAssertEqual(Set(tokens.keys), ["kinhin-1-r1", "kinhin-1-r2"])
        XCTAssertNotEqual(tokens["kinhin-1-r1"], tokens["kinhin-1-r2"], "each runner has its own token")
        XCTAssertEqual(server.createdTags, [["macos", "kinhin-host"], ["macos", "kinhin-host"]])

        // Just created, never contacted: listed (so cleanup finds them) but not online.
        let runners = try await forge.runners()
        XCTAssertEqual(runners.map(\.name).sorted(), ["kinhin-1-r1", "kinhin-1-r2"])
        XCTAssertTrue(runners.allSatisfy { !$0.online })
    }

    func testQueuedJobsNeedEveryAccountLabel() async throws {
        let server = FakeGitLabServer()
        server.pending = [
            (1, "build", ["macos"]),
            (2, "host-build", ["macos", "kinhin-host"]),
            (3, "linux", ["docker"]),
            (4, "untagged", []),
        ]
        let jobs = try await makeForge(server: server).queuedJobs()
        XCTAssertEqual(jobs.map(\.name), ["build", "host-build"])
        XCTAssertEqual(jobs.first?.repository, "acme/api")
        XCTAssertEqual(jobs.last?.labels, ["macos", "kinhin-host"], "tags route the job to a pool")
    }

    func testRunningJobsMarkTheirRunnersBusy() async throws {
        let server = FakeGitLabServer()
        let forge = makeForge(server: server)
        _ = try await forge.registrationTokens(runnerNames: ["kinhin-1"], labels: [])
        server.setStatus("kinhin-1", "online")
        server.running = [(9, "test", ["macos"], "kinhin-1")]

        let running = try await forge.runningJobs()
        XCTAssertEqual(running.first?.runnerName, "kinhin-1")
        let runner = try await forge.runners().first
        XCTAssertEqual(runner?.busy, true)
        XCTAssertEqual(runner?.online, true)
    }

    // MARK: Engine round trip

    func testEngineRunsAGitLabInstanceUntilItsRunnerDeletesItself() async throws {
        let server = FakeGitLabServer()
        server.pending = [(1, "build", ["macos"])]
        let forge = makeForge(server: server)
        let config = try ConfigLoader.parse(
            """
            labels: [macos]
            accounts:
              - name: gitlab
                forge: gitlab
                scope: acme/api
            """)
        var cfg = config
        cfg.pollInterval = 5
        cfg.vmBootTimeout = 30
        let tart = FakeTart()
        let ssh = FakeSSH()
        let engine = FleetEngine(
            config: cfg, github: FakeGitHub(), tart: tart, store: makeTestStore(), ssh: ssh, host: testHost)
        engine.forgeState.withLock { $0.byPlatform["gitlab"] = forge }

        try await engine.reconcileOnce()
        try await waitUntil { server.runnerNames.count == 1 }
        let id = try XCTUnwrap(server.runnerNames.first)

        // The registration script starts run-single with the created runner's token.
        try await waitUntil { !ssh.scripts.isEmpty }
        let script = try XCTUnwrap(ssh.scripts.last)
        XCTAssertTrue(script.contains("run-single"), script)
        XCTAssertTrue(script.contains("glrt-\(id)"), "the runner's own token is written for the agent")

        // The agent connects and takes the job, then deletes its runner.
        server.setStatus(id, "online")
        server.pending = []
        server.running = [(1, "build", ["macos"], id)]
        _ = try await forge.runningJobs()
        try await waitUntil { await engine.status().records.first?.phase == .busy }

        server.running = []
        server.deleteRunner(named: id)
        try await waitUntil { await engine.status().records.isEmpty }
        XCTAssertTrue(tart.deleteCalls.contains(id), "the VM is deleted once its runner is gone")
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("condition not met within \(timeout)s")
    }
}

/// A minimal GitLab: runners created through `POST /user/runners`, listed
/// and deleted, plus scripted pending and running jobs for one project.
final class FakeGitLabServer: @unchecked Sendable {
    private struct Runner {
        let id: Int
        let name: String
        var status: String
    }

    private let lock = NSLock()
    private var runners: [Runner] = []
    private var nextID = 1
    private var _createdTags: [[String]] = []
    private var _pending: [(Int, String, [String])] = []
    private var _running: [(Int, String, [String], String)] = []

    var createdTags: [[String]] { locked { _createdTags } }
    var runnerNames: [String] { locked { runners.map(\.name) } }
    var pending: [(Int, String, [String])] {
        get { locked { _pending } }
        set { locked { _pending = newValue } }
    }
    var running: [(Int, String, [String], String)] {
        get { locked { _running } }
        set { locked { _running = newValue } }
    }

    func setStatus(_ name: String, _ status: String) {
        locked {
            if let index = runners.firstIndex(where: { $0.name == name }) { runners[index].status = status }
        }
    }

    func deleteRunner(named name: String) {
        locked { runners.removeAll { $0.name == name } }
    }

    func handle(_ request: URLRequest) -> (Int, Data, [String: String]) {
        let path = request.url?.path ?? ""
        let query = request.url?.query ?? ""
        switch (request.httpMethod ?? "GET", path) {
        case ("POST", "/api/v4/user/runners"):
            let json = (try? JSONSerialization.jsonObject(with: bodyData(request))) as? [String: Any] ?? [:]
            let name = json["description"] as? String ?? ""
            let id: Int = locked {
                let id = nextID
                nextID += 1
                runners.append(Runner(id: id, name: name, status: "never_contacted"))
                _createdTags.append(json["tag_list"] as? [String] ?? [])
                return id
            }
            return json201(#"{"id":\#(id),"token":"glrt-\#(name)"}"#)
        case ("GET", "/api/v4/projects/7/runners"):
            let body = locked {
                runners.map { #"{"id":\#($0.id),"description":"\#($0.name)","status":"\#($0.status)"}"# }
            }
            return (200, Data("[\(body.joined(separator: ","))]".utf8), [:])
        case ("GET", "/api/v4/projects/7/jobs"):
            let rows: [String]
            if query.contains("running") {
                rows = running.map { job in
                    #"{"id":\#(job.0),"name":"\#(job.1)","tag_list":\#(tags(job.2)),"runner":{"description":"\#(job.3)"}}"#
                }
            } else {
                rows = pending.map { #"{"id":\#($0.0),"name":"\#($0.1)","tag_list":\#(tags($0.2))}"# }
            }
            return (200, Data("[\(rows.joined(separator: ","))]".utf8), [:])
        case ("DELETE", _) where path.hasPrefix("/api/v4/runners/"):
            let id = Int(path.split(separator: "/").last ?? "") ?? -1
            locked { runners.removeAll { $0.id == id } }
            return (204, Data(), [:])
        default:
            return (404, Data(), [:])
        }
    }

    private func json201(_ body: String) -> (Int, Data, [String: String]) { (201, Data(body.utf8), [:]) }

    private func tags(_ tags: [String]) -> String {
        "[" + tags.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    private func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
