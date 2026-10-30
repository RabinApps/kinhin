import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Gitea, Forgejo and Azure DevOps supply job identifiers, queue and start times, and a finished job's verdict, so
/// telemetry reports a real `cicd.pipeline.result` there too. (Bitbucket cannot say which runner took a step, so a
/// running step cannot be tied to a VM and it stays `unknown`.)
final class TelemetryForgeOutcomeGiteaAzureTests: XCTestCase {
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

    func testGiteaStatusMapping() {
        typealias R = JobOutcome.Result
        XCTAssertEqual(JobOutcome.result(giteaStatus: "success"), R.success)
        XCTAssertEqual(JobOutcome.result(giteaStatus: "failure"), R.failure)
        XCTAssertEqual(JobOutcome.result(giteaStatus: "cancelled"), R.cancellation)
        XCTAssertEqual(JobOutcome.result(giteaStatus: "skipped"), R.skip)
        XCTAssertNil(JobOutcome.result(giteaStatus: "unknown"), "a task that never ran has no verdict")
        XCTAssertNil(JobOutcome.result(giteaStatus: "running"))
        XCTAssertTrue(JobOutcome.isFinished(giteaStatus: "unknown"))
        XCTAssertTrue(JobOutcome.isFinished(giteaStatus: "failure"))
        XCTAssertFalse(JobOutcome.isFinished(giteaStatus: "running"))
        XCTAssertFalse(JobOutcome.isFinished(giteaStatus: "waiting"))
        XCTAssertFalse(JobOutcome.isFinished(giteaStatus: nil))
    }

    func testAzureResultMapping() {
        typealias R = JobOutcome.Result
        XCTAssertEqual(JobOutcome.result(azureResult: "succeeded"), R.success)
        XCTAssertEqual(JobOutcome.result(azureResult: "succeededWithIssues"), R.success)
        XCTAssertEqual(JobOutcome.result(azureResult: "failed"), R.failure)
        XCTAssertEqual(JobOutcome.result(azureResult: "canceled"), R.cancellation)
        XCTAssertEqual(JobOutcome.result(azureResult: "abandoned"), R.cancellation)
        XCTAssertEqual(JobOutcome.result(azureResult: "skipped"), R.skip)
        XCTAssertNil(JobOutcome.result(azureResult: nil))
    }

    // MARK: - Gitea

    private func giteaForge(_ family: ForgeID = .gitea) -> GiteaForge {
        let client = GiteaClient(
            credentials: GiteaCredentials(token: "gt", scope: "acme/api", instance: "https://gitea.example.com"),
            session: session())
        return GiteaForge(
            credentials: .gitea(token: "gt", scope: "acme/api", instance: "https://gitea.example.com"),
            labels: ["macos"], client: client, registrationToken: "reg")
    }

    func testGiteaRunningTaskCarriesIdentifiersAndTimes() async throws {
        StubProtocol.handler = { _ in
            let json = """
                {"total_count": 1, "workflow_runs": [{"id": 31, "name": "build", "status": "running",
                  "runner_name": "kinhin-1", "repo_full_name": "acme/api", "run_number": 8,
                  "created_at": "2026-01-02T03:00:00Z", "run_started_at": "2026-01-02T03:00:30Z"}]}
                """
            return (200, Data(json.utf8), [:])
        }
        let jobs = try await giteaForge().runningJobs()
        let correlation = try XCTUnwrap(jobs.first?.correlation)
        XCTAssertEqual(correlation.jobID, "31")
        XCTAssertEqual(correlation.runID, "8")
        XCTAssertEqual(correlation.jobName, "build")
        XCTAssertEqual(correlation.repository, "acme/api")
        XCTAssertNotNil(correlation.enqueuedAt)
        XCTAssertNotNil(correlation.startedAt)
    }

    func testGiteaFinishedTaskReportsItsVerdictAndTimes() async throws {
        StubProtocol.handler = { request in
            XCTAssertFalse(request.url!.absoluteString.contains("status="), "finished tasks are in the unfiltered list")
            let json = """
                {"total_count": 2, "workflow_runs": [
                  {"id": 40, "name": "other", "status": "success"},
                  {"id": 31, "name": "build", "status": "failure", "run_started_at": "2026-01-02T03:00:30Z",
                   "updated_at": "2026-01-02T03:02:30Z"}]}
                """
            return (200, Data(json.utf8), [:])
        }
        let outcome = try await giteaForge().jobOutcome(for: JobCorrelation(jobID: "31"))
        XCTAssertEqual(outcome?.result, .failure)
        let start = try XCTUnwrap(outcome?.startedAt)
        XCTAssertEqual(try XCTUnwrap(outcome?.completedAt).timeIntervalSince(start), 120)
    }

    func testGiteaRunningOrMissingTaskHasNoVerdict() async throws {
        StubProtocol.handler = { _ in
            (200, Data(#"{"workflow_runs": [{"id": 31, "name": "build", "status": "running"}]}"#.utf8), [:])
        }
        let forge = giteaForge()
        let running = try await forge.jobOutcome(for: JobCorrelation(jobID: "31"))
        XCTAssertEqual(running, JobOutcome())
        let missing = try await forge.jobOutcome(for: JobCorrelation(jobID: "99"))
        XCTAssertNil(missing)
        let noID = try await forge.jobOutcome(for: JobCorrelation())
        XCTAssertNil(noID)
    }

    // MARK: - Azure DevOps

    private func azureForge() -> AzureDevOpsForge {
        let credentials = AzureDevOpsCredentials(
            token: "pat", scope: "Mac Fleet", instance: "https://dev.azure.com/acme")
        return AzureDevOpsForge(
            credentials: ForgeCredentials(
                forge: .azuredevops, token: "pat", scope: "Mac Fleet", instance: "https://dev.azure.com/acme"),
            labels: ["kinhin"], client: AzureDevOpsClient(credentials: credentials, session: session()),
            pool: AzureDevOpsPool(id: 12, name: "Mac Fleet"), listTTL: 0)
    }

    func testAzureQueuedRequestCarriesIdentifiersAndQueueTime() async throws {
        StubProtocol.handler = { _ in
            let json = """
                {"count": 1, "value": [{"requestId": 77, "jobName": "Job", "queueTime": "2026-01-02T03:00:00Z",
                  "demands": ["kinhin"], "definition": {"name": "app-ci"}, "owner": {"id": 5, "name": "app-ci"}}]}
                """
            return (200, Data(json.utf8), [:])
        }
        let jobs = try await azureForge().queuedJobs()
        let correlation = try XCTUnwrap(jobs.first?.correlation)
        XCTAssertEqual(correlation.jobID, "77")
        XCTAssertEqual(correlation.runID, "5")
        XCTAssertEqual(correlation.workflow, "app-ci")
        XCTAssertNotNil(correlation.enqueuedAt)
        XCTAssertNil(correlation.startedAt)
    }

    func testAzureFinishedRequestReportsItsVerdictAndTimes() async throws {
        StubProtocol.handler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("completedRequestCount=100"), "\(request.url!)")
            let json = """
                {"count": 2, "value": [
                  {"requestId": 76, "jobName": "x", "result": "succeeded"},
                  {"requestId": 77, "jobName": "Job", "result": "failed", "assignTime": "2026-01-02T03:00:10Z",
                   "finishTime": "2026-01-02T03:01:10Z"}]}
                """
            return (200, Data(json.utf8), [:])
        }
        let outcome = try await azureForge().jobOutcome(for: JobCorrelation(jobID: "77"))
        XCTAssertEqual(outcome?.result, .failure)
        let start = try XCTUnwrap(outcome?.startedAt)
        XCTAssertEqual(try XCTUnwrap(outcome?.completedAt).timeIntervalSince(start), 60)
    }

    func testAzureRunningOrMissingRequestHasNoVerdict() async throws {
        StubProtocol.handler = { _ in
            (200, Data(#"{"count": 1, "value": [{"requestId": 77, "assignTime": "2026-01-02T03:00:10Z"}]}"#.utf8), [:])
        }
        let forge = azureForge()
        let running = try await forge.jobOutcome(for: JobCorrelation(jobID: "77"))
        XCTAssertEqual(running, JobOutcome())
        let missing = try await forge.jobOutcome(for: JobCorrelation(jobID: "1"))
        XCTAssertNil(missing)
    }
}
