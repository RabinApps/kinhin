import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// GitLab and Buildkite supply job identifiers, queue and start times, and a finished job's verdict, so telemetry
/// reports a real `cicd.pipeline.result` there and not just on GitHub.
final class TelemetryForgeOutcomeTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - Status mappings

    func testGitLabStatusMapping() {
        typealias R = JobOutcome.Result
        XCTAssertEqual(JobOutcome.result(gitLabStatus: "success"), R.success)
        XCTAssertEqual(JobOutcome.result(gitLabStatus: "failed", failureReason: "script_failure"), R.failure)
        XCTAssertEqual(JobOutcome.result(gitLabStatus: "failed", failureReason: "job_execution_timeout"), R.timeout)
        XCTAssertEqual(JobOutcome.result(gitLabStatus: "canceled"), R.cancellation)
        XCTAssertEqual(JobOutcome.result(gitLabStatus: "skipped"), R.skip)
        XCTAssertNil(JobOutcome.result(gitLabStatus: "running"))
        XCTAssertNil(JobOutcome.result(gitLabStatus: "manual"))
        XCTAssertTrue(JobOutcome.isFinished(gitLabStatus: "failed"))
        XCTAssertFalse(JobOutcome.isFinished(gitLabStatus: "running"))
        XCTAssertFalse(JobOutcome.isFinished(gitLabStatus: nil))
    }

    func testBuildkiteStateMapping() {
        typealias R = JobOutcome.Result
        XCTAssertEqual(JobOutcome.result(buildkiteState: "passed", exitStatus: nil), R.success)
        XCTAssertEqual(JobOutcome.result(buildkiteState: "failed", exitStatus: 1), R.failure)
        XCTAssertEqual(JobOutcome.result(buildkiteState: "finished", exitStatus: 0), R.success)
        XCTAssertEqual(JobOutcome.result(buildkiteState: "finished", exitStatus: 2), R.failure)
        XCTAssertNil(JobOutcome.result(buildkiteState: "finished", exitStatus: nil), "no exit status, no guess")
        XCTAssertEqual(JobOutcome.result(buildkiteState: "timed_out", exitStatus: nil), R.timeout)
        XCTAssertEqual(JobOutcome.result(buildkiteState: "canceled", exitStatus: nil), R.cancellation)
        XCTAssertEqual(JobOutcome.result(buildkiteState: "skipped", exitStatus: nil), R.skip)
        XCTAssertNil(JobOutcome.result(buildkiteState: "running", exitStatus: nil))
        XCTAssertFalse(JobOutcome.isFinished(buildkiteState: "scheduled"))
        XCTAssertTrue(JobOutcome.isFinished(buildkiteState: "finished"))
    }

    // MARK: - GitLab

    private func gitLabForge() -> GitLabForge {
        let client = GitLabClient(
            credentials: GitLabCredentials(token: "glpat", scope: "acme/api"), session: session())
        return GitLabForge(
            credentials: .gitlab(token: "glpat", scope: "acme/api", instance: GitLabCredentials.defaultInstance),
            labels: ["macos"], poolLabels: [], client: client, scope: .project(id: 7, path: "acme/api"),
            runnerListTTL: 0)
    }

    func testGitLabQueuedJobCarriesIdentifiersAndTimes() async throws {
        StubProtocol.handler = { _ in
            let json = """
                [{"id": 55, "name": "build", "tag_list": ["macos"], "ref": "main", "commit": {"id": "abc"},
                  "pipeline": {"id": 9, "source": "push", "ref": "main"},
                  "created_at": "2026-01-02T03:04:05.000Z", "started_at": null}]
                """
            return (200, Data(json.utf8), [:])
        }
        let jobs = try await gitLabForge().queuedJobs()
        let correlation = try XCTUnwrap(jobs.first?.correlation)
        XCTAssertEqual(correlation.runID, "9")
        XCTAssertEqual(correlation.jobID, "55")
        XCTAssertEqual(correlation.jobName, "build")
        XCTAssertEqual(correlation.repository, "acme/api")
        XCTAssertNotNil(correlation.enqueuedAt)
        XCTAssertNil(correlation.startedAt)
    }

    func testGitLabFinishedJobReportsItsVerdictAndTimes() async throws {
        StubProtocol.handler = { request in
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/projects/acme%2Fapi/jobs/55"), "\(request.url!)")
            let json = """
                {"id": 55, "status": "failed", "failure_reason": "script_failure",
                 "started_at": "2026-01-02T03:04:10.000Z", "finished_at": "2026-01-02T03:05:10.000Z"}
                """
            return (200, Data(json.utf8), [:])
        }
        let outcome = try await gitLabForge().jobOutcome(
            for: JobCorrelation(runID: "9", jobID: "55", repository: "acme/api"))
        XCTAssertEqual(outcome?.result, .failure)
        let start = try XCTUnwrap(outcome?.startedAt)
        XCTAssertEqual(try XCTUnwrap(outcome?.completedAt).timeIntervalSince(start), 60)
        XCTAssertTrue(outcome?.steps.isEmpty ?? false, "GitLab has no step list below the job")
    }

    func testGitLabUnfinishedJobHasNoVerdictYet() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"id": 55, "status": "running"}"#.utf8), [:]) }
        let outcome = try await gitLabForge().jobOutcome(
            for: JobCorrelation(runID: "9", jobID: "55", repository: "acme/api"))
        XCTAssertEqual(outcome, JobOutcome())
    }

    func testGitLabNeedsAProjectAndAJobID() async throws {
        let forge = gitLabForge()
        let noID = try await forge.jobOutcome(for: JobCorrelation(repository: "acme/api"))
        XCTAssertNil(noID)
        let noProject = try await forge.jobOutcome(for: JobCorrelation(jobID: "5"))
        XCTAssertNil(noProject)
    }

    // MARK: - Buildkite

    private func buildkiteForge() -> BuildkiteForge {
        BuildkiteForge(
            credentials: ForgeCredentials(forge: .buildkite, token: "bkua", scope: "acme/Mac Fleet"),
            labels: ["queue=kinhin"],
            client: BuildkiteClient(
                credentials: BuildkiteCredentials(token: "bkua", scope: "acme/Mac Fleet"), session: session()),
            cluster: BuildkiteCluster(id: "c-1", name: "Mac Fleet"), agentToken: "bkct", account: "ci", listTTL: 0)
    }

    func testBuildkiteQueuedJobCarriesBuildAndRunnableTime() async throws {
        StubProtocol.handler = { _ in
            let json = """
                [{"number": 12, "state": "scheduled", "pipeline": {"slug": "app", "name": "App"},
                  "jobs": [{"id": "j-1", "type": "script", "name": "test", "state": "scheduled",
                            "agent_query_rules": ["queue=kinhin"], "cluster_id": "c-1",
                            "created_at": "2026-01-02T03:00:00.000Z", "runnable_at": "2026-01-02T03:01:00.000Z"}]}]
                """
            return (200, Data(json.utf8), [:])
        }
        let jobs = try await buildkiteForge().queuedJobs()
        let correlation = try XCTUnwrap(jobs.first?.correlation)
        XCTAssertEqual(correlation.runID, "12")
        XCTAssertEqual(correlation.jobID, "j-1")
        XCTAssertEqual(correlation.workflow, "app")
        let queued = try XCTUnwrap(correlation.enqueuedAt)
        XCTAssertEqual(
            queued, ISO8601DateFormatter().date(from: "2026-01-02T03:01:00Z"), "runnable_at beats created_at")
    }

    func testBuildkiteFinishedJobReportsItsVerdictFromTheBuild() async throws {
        StubProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/pipelines/app/builds/12"), "\(request.url!)")
            let json = """
                {"number": 12, "state": "failed", "pipeline": {"slug": "app"},
                 "jobs": [{"id": "j-1", "type": "script", "name": "test", "state": "finished", "exit_status": 3,
                           "started_at": "2026-01-02T03:01:10.000Z", "finished_at": "2026-01-02T03:03:10.000Z"},
                          {"id": "j-2", "type": "script", "name": "other", "state": "passed"}]}
                """
            return (200, Data(json.utf8), [:])
        }
        let outcome = try await buildkiteForge().jobOutcome(
            for: JobCorrelation(runID: "12", jobID: "j-1", repository: "app"))
        XCTAssertEqual(outcome?.result, .failure)
        let start = try XCTUnwrap(outcome?.startedAt)
        XCTAssertEqual(try XCTUnwrap(outcome?.completedAt).timeIntervalSince(start), 120)
    }

    func testBuildkiteRunningJobHasNoVerdictYetAndUnknownJobIsNil() async throws {
        StubProtocol.handler = { _ in
            let json = """
                {"number": 12, "pipeline": {"slug": "app"},
                 "jobs": [{"id": "j-1", "type": "script", "name": "test", "state": "running"}]}
                """
            return (200, Data(json.utf8), [:])
        }
        let forge = buildkiteForge()
        let running = try await forge.jobOutcome(for: JobCorrelation(runID: "12", jobID: "j-1", repository: "app"))
        XCTAssertEqual(running, JobOutcome())
        let missing = try await forge.jobOutcome(for: JobCorrelation(runID: "12", jobID: "gone", repository: "app"))
        XCTAssertNil(missing)
        let noBuild = try await forge.jobOutcome(for: JobCorrelation(jobID: "j-1", repository: "app"))
        XCTAssertNil(noBuild)
    }
}
