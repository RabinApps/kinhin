import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Per-repo job attribution: which repository each queued job came from,
/// surfaced in org scope where one fleet serves many repos. Covers running
/// work too: in-progress jobs are mapped back to VMs via runner_name and
/// stamped on the VM record through its lifecycle.
final class QueueAttributionTests: XCTestCase {
    // MARK: - Client parsing

    func testClientExtractsRepositoryFromRunsResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GitHubClient(
            credentials: GitHubCredentials(token: "t", scope: "acme"),
            session: URLSession(configuration: config)
        )
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/orgs/acme/actions/runs" {
                XCTFail("org runs endpoint must never be called")
                return (404, Data("{\"message\":\"Not Found\"}".utf8), [:])
            }
            if path == "/orgs/acme/repos" {
                return (200, Data("[{\"full_name\":\"acme/ios-app\"},{\"full_name\":\"acme/api\"}]".utf8), [:])
            }
            if path == "/repos/acme/ios-app/actions/runs" {
                return (200, Data("{\"total_count\":1,\"workflow_runs\":[{\"id\":1}]}".utf8), [:])
            }
            if path == "/repos/acme/api/actions/runs" {
                return (200, Data("{\"total_count\":1,\"workflow_runs\":[{\"id\":2}]}".utf8), [:])
            }
            if path == "/repos/acme/ios-app/actions/runs/1/jobs" {
                return (
                    200,
                    Data(
                        """
                        {"jobs":[{"id":11,"run_id":1,"name":"build","status":"queued","labels":["self-hosted"]}]}
                        """.utf8),
                    [:]
                )
            }
            if path == "/repos/acme/api/actions/runs/2/jobs" {
                return (
                    200,
                    Data(
                        """
                        {"jobs":[{"id":22,"run_id":2,"name":"test","status":"queued","labels":["self-hosted"]}]}
                        """.utf8),
                    [:]
                )
            }
            XCTFail("unexpected path: \(path)")
            return (404, Data(), [:])
        }
        defer { StubProtocol.handler = nil }

        let jobs = try await client.queuedJobs(matching: ["self-hosted"])
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs.first { $0.jobID == 11 }?.repository, "acme/ios-app")
        XCTAssertEqual(jobs.first { $0.jobID == 22 }?.repository, "acme/api")
    }

    func testClientParsesRunningJobsWithRunnerName() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GitHubClient(
            credentials: GitHubCredentials(token: "t", scope: "acme"),
            session: URLSession(configuration: config)
        )
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/orgs/acme/actions/runs" {
                XCTFail("org runs endpoint must never be called")
                return (404, Data("{\"message\":\"Not Found\"}".utf8), [:])
            }
            if path == "/orgs/acme/repos" {
                return (200, Data("[{\"full_name\":\"acme/ios-app\"}]".utf8), [:])
            }
            if path == "/repos/acme/ios-app/actions/runs" {
                return (
                    200,
                    Data(
                        """
                        {"total_count":1,"workflow_runs":[{"id":9,"repository":{"full_name":"acme/ios-app"}}]}
                        """.utf8),
                    [:]
                )
            }
            if path == "/repos/acme/ios-app/actions/runs/9/jobs" {
                return (
                    200,
                    Data(
                        """
                        {"jobs":[{"id":77,"run_id":9,"name":"build","status":"in_progress","labels":["self-hosted"],"runner_name":"kinhin-123-a1-r2"}]}
                        """.utf8),
                    [:]
                )
            }
            XCTFail("unexpected path: \(path)")
            return (404, Data(), [:])
        }
        defer { StubProtocol.handler = nil }

        let jobs = try await client.runningJobs(matching: ["self-hosted"])
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].name, "build")
        XCTAssertEqual(jobs[0].runnerName, "kinhin-123-a1-r2")
        XCTAssertEqual(jobs[0].repository, "acme/ios-app")
    }

    func testRunningJobsRequestFiltersByInProgress() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GitHubClient(
            credentials: GitHubCredentials(token: "t", scope: "acme"),
            session: URLSession(configuration: config)
        )
        // The @Sendable stub handler records the query item; Mutex keeps the
        // hand-off to the test's assertion race-free.
        let runsStatus = Locked<String?>(nil)
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/orgs/acme/repos" {
                return (200, Data("[{\"full_name\":\"acme/widgets\"}]".utf8), [:])
            }
            if path == "/repos/acme/widgets/actions/runs" {
                runsStatus.withLock {
                    $0 =
                        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "status" })?.value
                }
                return (200, Data("{\"total_count\":0,\"workflow_runs\":[]}".utf8), [:])
            }
            XCTFail("unexpected path: \(path)")
            return (404, Data(), [:])
        }
        defer { StubProtocol.handler = nil }

        _ = try await client.runningJobs(matching: ["self-hosted"])
        XCTAssertEqual(
            runsStatus.withLock { $0 }, "in_progress", "running-jobs polling must use in_progress, not queued")
    }

    // MARK: - Engine aggregation

    func makeEngine(scope: String, github: FakeGitHub) -> FleetEngine {
        var cfg = makeTestConfig()
        cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: scope)]
        return FleetEngine(
            config: cfg, github: github, tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost
        )
    }

    func testOrgScopeAggregatesQueueByRepo() async throws {
        let github = FakeGitHub()
        github.queueDepth = 4
        github.queueRepos = ["acme/ios-app", "acme/api"]
        let engine = makeEngine(scope: "acme", github: github)

        try await engine.reconcileOnce()
        let status = await engine.status()
        XCTAssertEqual(status.queueDepth, 4)
        XCTAssertEqual(status.queueByRepo, ["acme/ios-app": 2, "acme/api": 2])
    }

    func testRepoScopeHasNoRepoBreakdown() async throws {
        let github = FakeGitHub()
        github.queueDepth = 3
        github.queueRepos = ["acme/widgets"]  // same repo anyway
        let engine = makeEngine(scope: "acme/widgets", github: github)

        try await engine.reconcileOnce()
        let status = await engine.status()
        XCTAssertEqual(status.queueDepth, 3)
        XCTAssertNil(status.queueByRepo, "single-repo fleet: breakdown would carry no information")
    }

    func testOrgScopeWithMissingRepositoryFieldDegradesGracefully() async throws {
        let github = FakeGitHub()
        github.queueDepth = 2
        github.queueRepos = []  // API returned no repository info
        let engine = makeEngine(scope: "acme", github: github)

        try await engine.reconcileOnce()
        let status = await engine.status()
        XCTAssertEqual(status.queueDepth, 2)
        XCTAssertEqual(status.queueByRepo, [:], "attribution unknown but org scope still reports the empty map")
    }

    func testQueueByRepoSurvivesStatusJSONRoundTrip() throws {
        var status = FleetStatus()
        status.queueDepth = 5
        status.queueByRepo = ["acme/ios-app": 3, "acme/api": 2]
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(FleetStatus.self, from: data)
        XCTAssertEqual(decoded.queueByRepo, status.queueByRepo)
    }

    func testAutoResumeSurvivesStatusJSONRoundTrip() throws {
        // A daemon predating the field decodes autoResume as nil (off).
        let json =
            "{\"running\":true,\"paused\":true,\"queueDepth\":0,\"desired\":0,\"capacityCap\":0,\"jobCapacity\":0,"
            + "\"records\":[],\"updatedAt\":0}"
        let legacy = try JSONDecoder().decode(FleetStatus.self, from: Data(json.utf8))
        XCTAssertNil(legacy.autoResume)

        var status = FleetStatus()
        status.autoResume = true
        let decoded = try JSONDecoder().decode(FleetStatus.self, from: try JSONEncoder().encode(status))
        XCTAssertEqual(decoded.autoResume, true)
    }

    // MARK: - Running-job attribution (engine)

    func testRunningJobStampsVMRecordInOrgScope() async throws {
        let github = FakeGitHub()
        let engine = makeEngine(scope: "acme", github: github)

        // Spawn one VM and wait for it to go ready (runner registered).
        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.first?.phase == .ready
        }
        let vmID = await engine.status().records.first!.id

        // A job is now running on that VM's runner; the repo is attributed.
        github.running = [RunningJob(name: "build", runnerName: vmID, repository: "acme/ios-app")]
        try await engine.reconcileOnce()

        let status = await engine.status()
        XCTAssertEqual(status.records.first?.repos, ["acme/ios-app"])
        XCTAssertEqual(status.records.first?.job, "build")
        XCTAssertEqual(status.runningByRepo, ["acme/ios-app": 1])
    }

    func testMultiRunnerVMDerivesVMIDFromIndexedRunnerName() async throws {
        let github = FakeGitHub()
        _ = makeEngine(scope: "acme", github: github)
        var cfg = makeTestConfig(repo: "acme")
        cfg.runnersPerVM = 3
        let denseEngine = FleetEngine(
            config: cfg, github: github, tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost
        )

        github.queueDepth = 1
        try await denseEngine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await denseEngine.status()
            return status.records.first?.phase == .ready
        }
        let vmID = await denseEngine.status().records.first!.id

        // Runner r2 of this VM is executing a job; attribution must map the
        // "<vmid>-r2" runner name back to the VM.
        github.running = [RunningJob(name: "test", runnerName: "\(vmID)-r2", repository: "acme/api")]
        try await denseEngine.reconcileOnce()

        let status = await denseEngine.status()
        XCTAssertEqual(status.records.first?.repos, ["acme/api"])
        XCTAssertEqual(status.runningByRepo, ["acme/api": 1])
    }

    func testEveryRunnerOfAMultiRunnerVMKeepsItsJob() async throws {
        let github = FakeGitHub()
        var cfg = makeTestConfig(repo: "acme")
        cfg.runnersPerVM = 3
        let engine = FleetEngine(
            config: cfg, github: github, tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost
        )
        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.first?.phase == .ready
        }
        let vmID = await engine.status().records.first!.id

        github.running = [
            RunningJob(name: "lint", runnerName: "\(vmID)-r3", repository: "acme/api"),
            RunningJob(name: "build", runnerName: "\(vmID)-r1", repository: "acme/api"),
            RunningJob(name: "test", runnerName: "\(vmID)-r2", repository: "acme/web"),
        ]
        try await engine.reconcileOnce()

        let record = await engine.status().records.first!
        XCTAssertEqual(
            record.runningJobs,
            [
                RunningJobStamp(runner: "\(vmID)-r1", job: "build", repo: "acme/api"),
                RunningJobStamp(runner: "\(vmID)-r2", job: "test", repo: "acme/web"),
                RunningJobStamp(runner: "\(vmID)-r3", job: "lint", repo: "acme/api"),
            ])
        XCTAssertEqual(record.job, "build")
        XCTAssertEqual(record.repos, ["acme/api", "acme/web"], "repos are deduplicated")
        XCTAssertEqual(FleetStatusFormatter.runningJobs(of: record).count, 3)

        github.running = []
        try await engine.reconcileOnce()
        let cleared = await engine.status().records.first!
        XCTAssertNil(cleared.runningJobs)
        XCTAssertNil(cleared.job)
    }

    func testRunningAttributionClearsWhenJobFinishes() async throws {
        let github = FakeGitHub()
        let engine = makeEngine(scope: "acme", github: github)

        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.first?.phase == .ready
        }
        let vmID = await engine.status().records.first!.id

        github.running = [RunningJob(name: "build", runnerName: vmID, repository: "acme/ios-app")]
        try await engine.reconcileOnce()
        var status = await engine.status()
        XCTAssertEqual(status.records.first?.repos, ["acme/ios-app"])

        // Job finishes: the next poll (no running jobs) must clear the stamp.
        github.running = []
        try await engine.reconcileOnce()
        status = await engine.status()
        XCTAssertNil(status.records.first?.repos)
        XCTAssertNil(status.records.first?.job)
        XCTAssertEqual(status.runningByRepo, [:])
    }

    func testRunningAttributionSuppressedInRepoScope() async throws {
        let github = FakeGitHub()
        let engine = makeEngine(scope: "acme/widgets", github: github)

        github.queueDepth = 1
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.first?.phase == .ready
        }
        let vmID = await engine.status().records.first!.id

        github.running = [RunningJob(name: "build", runnerName: vmID, repository: "acme/widgets")]
        try await engine.reconcileOnce()

        let status = await engine.status()
        XCTAssertNil(status.runningByRepo, "single-repo fleet: breakdown would carry no information")
        XCTAssertNil(status.records.first?.repos, "repo scope: per-VM attribution also suppressed")
        XCTAssertEqual(status.records.first?.job, "build", "job name is useful regardless of scope")
    }

    func testRunningByRepoSurvivesStatusJSONRoundTrip() throws {
        var status = FleetStatus()
        status.runningByRepo = ["acme/ios-app": 2, "acme/api": 1]
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(FleetStatus.self, from: data)
        XCTAssertEqual(decoded.runningByRepo, status.runningByRepo)
    }

    // MARK: - Helpers

}
