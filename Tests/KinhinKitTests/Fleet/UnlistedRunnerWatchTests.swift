import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The Gitea-family exit watch on a server with no runner list (Forgejo through v14: `GET …/actions/runners` is a
/// 404 and task entries carry no runner name), driven through the real `GiteaForge` and `GiteaClient` over stubbed
/// HTTP. Found live by the e2e suite: the watch retried the 404 forever and never deleted the instance.
final class UnlistedRunnerWatchTests: XCTestCase {
    /// What the stubbed server says; the test flips it while the watch runs.
    private final class Server: Sendable {
        struct State: Sendable {
            /// nil: `…/actions/runners` is a 404 (Forgejo). Otherwise the listed runners as (name, status).
            var runners: [(name: String, status: String)]?
            /// Task statuses, newest first.
            var tasks: [String] = []
            var runnerRequests = 0
            var taskRequests = 0
        }

        let state = Locked(State())

        func handle(_ request: URLRequest) -> (Int, Data, [String: String]) {
            let path = request.url?.path ?? ""
            if path.hasSuffix("/actions/runners") {
                return state.withLock { state in
                    state.runnerRequests += 1
                    guard let runners = state.runners else { return (404, Data("404 page not found".utf8), [:]) }
                    let items = runners.enumerated().map {
                        "{\"id\":\($0.offset + 1),\"name\":\"\($0.element.name)\",\"status\":\"\($0.element.status)\"}"
                    }
                    let body = "{\"total_count\":\(items.count),\"runners\":[\(items.joined(separator: ","))]}"
                    return (200, Data(body.utf8), [:])
                }
            }
            if path.hasSuffix("/actions/tasks") {
                return state.withLock { state in
                    state.taskRequests += 1
                    // The shape Forgejo 11 answers: `workflow_runs`, every status regardless of `?status=`, and no
                    // runner name on any entry.
                    let items = state.tasks.enumerated().map {
                        "{\"id\":\(100 - $0.offset),\"name\":\"job\",\"status\":\"\($0.element)\",\"run_number\":\(100 - $0.offset)}"
                    }
                    let body = "{\"workflow_runs\":[\(items.joined(separator: ","))],\"total_count\":\(items.count)}"
                    return (200, Data(body.utf8), [:])
                }
            }
            return (404, Data(), [:])
        }
    }

    private let server = Server()

    override func setUp() {
        super.setUp()
        let server = server
        StubProtocol.handler = { server.handle($0) }
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func makeForge() -> GiteaForge {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let credentials = GiteaCredentials(token: "gt", scope: "e2e/demo", instance: "https://forgejo.example.com")
        return GiteaForge(
            credentials: .forgejo(token: "gt", scope: "e2e/demo", instance: "https://forgejo.example.com"),
            labels: ["kinhin"],
            client: GiteaClient(credentials: credentials, session: URLSession(configuration: config)),
            registrationToken: "rt", activityTTL: .milliseconds(10))
    }

    private func makeEngine(tart: FakeTart, idleGrace: Duration) -> FleetEngine {
        FleetEngine(
            config: makeTestConfig(), github: FakeGitHub(), tart: tart, store: makeTestStore(), ssh: FakeSSH(),
            host: testHost,
            dependencies: .init(
                tokenLoader: { _, _ in "t" }, exitWatchInterval: .milliseconds(20),
                watchdog: Watchdog(livenessInterval: .seconds(3600), idleGrace: idleGrace)))
    }

    private func addInstance(_ id: String, to engine: FleetEngine, tart: FakeTart) {
        var record = VMRecord(id: id, phase: .ready)
        record.runtimeID = .tart
        engine.store.upsert(record)
        tart.vms[id] = TartVM(name: id, source: "base", status: "running")
    }

    private func watch(_ id: String, engine: FleetEngine, forge: Forge) -> Task<Void, Error> {
        Task { try await engine.awaitRunnerExit(id: id, forge: forge) }
    }

    private func isGone(_ id: String, engine: FleetEngine) -> Bool {
        !engine.store.all.contains { $0.id == id }
    }

    // MARK: - Restart recovery on a server with no runner list

    /// An engine whose `github` account is the listless server, with the recovered VMs on `tart`.
    private func makeRecoveryEngine(tart: FakeTart) -> FleetEngine {
        var config = makeTestConfig()
        config.vm.ephemeral = true
        let engine = FleetEngine(
            config: config, github: FakeGitHub(), tart: tart, store: makeTestStore(), ssh: FakeSSH(),
            host: testHost,
            dependencies: .init(
                tokenLoader: { _, _ in "t" }, exitWatchInterval: .milliseconds(20),
                watchdog: Watchdog(livenessInterval: .seconds(3600))))
        engine.forgeState.withLock { $0.byPlatform["github"] = makeForge() }
        return engine
    }

    /// Nothing is running in the scope, so a VM whose registration never completed cannot be disrupted by registering
    /// it. It must not be adopted as ready (it would wait forever for a runner that never registers).
    func testRecoveredVMIsRegisteredWhenNothingRunsOnAListlessServer() async throws {
        server.state.withLock { $0.tasks = ["success"] }
        let tart = FakeTart()
        tart.vms["kinhin-rc1"] = TartVM(name: "kinhin-rc1", source: "base", status: "running")
        let engine = makeRecoveryEngine(tart: tart)

        await engine.recoverIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertGreaterThan(server.state.withLock { $0.taskRequests }, 0, "the scope's activity was asked")
        let phase = engine.store.all.first { $0.id == "kinhin-rc1" }?.phase
        XCTAssertNotEqual(phase, .ready, "an unregistered VM is registered, not adopted as ready")
        XCTAssertNotEqual(phase, .busy, "an unregistered VM is registered, not adopted as busy")
        await engine.detachKeepingInstances()
    }

    /// A job is running in the scope, so this VM's runner cannot be told from the others: it is watched as busy, and
    /// nothing is registered over the running job.
    func testRecoveredVMIsWatchedBusyWhileAJobRunsOnAListlessServer() async throws {
        server.state.withLock { $0.tasks = ["running"] }
        let tart = FakeTart()
        tart.vms["kinhin-rc2"] = TartVM(name: "kinhin-rc2", source: "base", status: "running")
        let engine = makeRecoveryEngine(tart: tart)

        await engine.recoverIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(engine.store.all.first { $0.id == "kinhin-rc2" }?.phase, .busy)
        XCTAssertEqual(tart.deleteCalls, [], "a VM with a job running in its scope is not removed")
        await engine.detachKeepingInstances()
    }

    // MARK: - No runner list

    /// A job running in the scope keeps the instance, however long it takes; once it has finished and the grace
    /// has passed, the instance goes.
    func testRunningTaskKeepsTheInstanceAndFinishingItDeletesItAfterTheGrace() async throws {
        server.state.withLock { $0.tasks = ["running", "success"] }
        let tart = FakeTart()
        let engine = makeEngine(tart: tart, idleGrace: .milliseconds(300))
        addInstance("kinhin-fj1", to: engine, tart: tart)
        let task = watch("kinhin-fj1", engine: engine, forge: makeForge())
        defer { task.cancel() }

        // Several multiples of the grace with the job still running.
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(isGone("kinhin-fj1", engine: engine), "deleted while a job was running")
        XCTAssertEqual(engine.store.all.first?.phase, .busy)
        XCTAssertEqual(tart.deleteCalls, [])

        server.state.withLock { $0.tasks = ["success", "success"] }
        try await waitUntil(timeout: 10) { self.isGone("kinhin-fj1", engine: engine) }
        XCTAssertTrue(tart.deleteCalls.contains("kinhin-fj1"))
    }

    /// The next task of a queue starts a moment after the last one ends: a gap shorter than the grace must not
    /// read as "finished".
    func testGapBetweenTwoJobsInsideTheGraceDoesNotDelete() async throws {
        server.state.withLock { $0.tasks = ["running"] }
        let tart = FakeTart()
        let engine = makeEngine(tart: tart, idleGrace: .milliseconds(800))
        addInstance("kinhin-fj2", to: engine, tart: tart)
        let task = watch("kinhin-fj2", engine: engine, forge: makeForge())
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(300))
        server.state.withLock { $0.tasks = ["success"] }  // the first job ended, the next is not dispatched yet
        try await Task.sleep(for: .milliseconds(300))
        server.state.withLock { $0.tasks = ["running", "success"] }  // ...and now it is
        try await Task.sleep(for: .milliseconds(1500))  // well past one grace since the first job ended
        XCTAssertFalse(isGone("kinhin-fj2", engine: engine), "deleted between two queued jobs")

        server.state.withLock { $0.tasks = ["success", "success"] }
        try await waitUntil(timeout: 10) { self.isGone("kinhin-fj2", engine: engine) }
    }

    /// A runner that never receives a job is reclaimed once nothing runs in the scope, like on a listing server.
    func testIdleInstanceWithNoJobIsReclaimedAfterTheGrace() async throws {
        server.state.withLock { $0.tasks = [] }
        let tart = FakeTart()
        let engine = makeEngine(tart: tart, idleGrace: .milliseconds(200))
        addInstance("kinhin-fj3", to: engine, tart: tart)
        let task = watch("kinhin-fj3", engine: engine, forge: makeForge())
        defer { task.cancel() }

        try await waitUntil(timeout: 10) { self.isGone("kinhin-fj3", engine: engine) }
    }

    /// Another instance's job is running in the same scope: this one cannot be told apart from the busy one, so
    /// it stays.
    func testOtherInstancesJobInTheScopeKeepsAnIdleInstanceAlive() async throws {
        server.state.withLock { $0.tasks = ["running"] }
        let tart = FakeTart()
        let engine = makeEngine(tart: tart, idleGrace: .milliseconds(100))
        addInstance("kinhin-fj4", to: engine, tart: tart)
        let task = watch("kinhin-fj4", engine: engine, forge: makeForge())
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(isGone("kinhin-fj4", engine: engine))
    }

    /// The 404 is learned once, not asked on every poll of every watcher.
    func testAbsentRunnerListIsRememberedAcrossPolls() async throws {
        server.state.withLock { $0.tasks = ["running"] }
        let tart = FakeTart()
        let engine = makeEngine(tart: tart, idleGrace: .seconds(30))
        addInstance("kinhin-fj5", to: engine, tart: tart)
        let forge = makeForge()
        let task = watch("kinhin-fj5", engine: engine, forge: forge)
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(600))  // ~30 polls
        XCTAssertEqual(server.state.withLock { $0.runnerRequests }, 1)
        XCTAssertGreaterThan(server.state.withLock { $0.taskRequests }, 1)
        // Running-job attribution does not fail on the missing list either.
        let running = try await forge.runningJobs()
        XCTAssertEqual(running, [])
        XCTAssertEqual(server.state.withLock { $0.runnerRequests }, 1)
    }

    // MARK: - A runner list (Gitea 1.24+)

    /// The listing path is untouched: busy per the list, idle per the list, and the task queue is never consulted.
    func testListedRunnersStillDriveTheWatch() async throws {
        server.state.withLock {
            $0.runners = [(name: "kinhin-gt1", status: "busy")]
            $0.tasks = []
        }
        let tart = FakeTart()
        let engine = makeEngine(tart: tart, idleGrace: .milliseconds(300))
        addInstance("kinhin-gt1", to: engine, tart: tart)
        let task = watch("kinhin-gt1", engine: engine, forge: makeForge())
        defer { task.cancel() }

        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertFalse(isGone("kinhin-gt1", engine: engine), "deleted while the listed runner was busy")
        XCTAssertEqual(engine.store.all.first?.phase, .busy)

        server.state.withLock { $0.runners = [(name: "kinhin-gt1", status: "idle")] }
        try await waitUntil(timeout: 10) { self.isGone("kinhin-gt1", engine: engine) }
        XCTAssertEqual(server.state.withLock { $0.taskRequests }, 0, "a listing server never reads the task queue")
    }
}
