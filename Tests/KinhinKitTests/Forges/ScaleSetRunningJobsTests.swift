import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// A scale-set job's `runs-on:` is the scale-set name, not the fleet's labels, so the running-jobs read must not
/// filter on them (the Fleet tab's Current jobs stayed empty while a container was busy).
final class ScaleSetRunningJobsTests: XCTestCase {
    func testRunningJobsIgnoreFleetLabelsAndKeepCorrelation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GitHubClient(
            credentials: GitHubCredentials(token: "t", scope: "acme/api"),
            session: URLSession(configuration: config))
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/repos/acme/api/actions/runs" {
                return (200, Data(#"{"total_count":1,"workflow_runs":[{"id":9}]}"#.utf8), [:])
            }
            if path == "/repos/acme/api/actions/runs/9/jobs" {
                let job =
                    #"{"jobs":[{"id":77,"run_id":9,"name":"build","status":"in_progress","#
                    + #""labels":["kinhin-container"],"runner_name":"kinhin-1-r1","#
                    + #""created_at":"2026-11-21T10:00:00Z"}]}"#
                return (200, Data(job.utf8), [:])
            }
            return (404, Data(), [:])
        }
        defer { StubProtocol.handler = nil }
        let listener = GitHubScaleSetListener(
            client: GitHubScaleSetClient(credentials: GitHubCredentials(token: "t", scope: "acme/api")),
            scaleSetIdSupplier: { 1 }, ownerName: "acme", fallbackRepository: "acme/api",
            pollInterval: .seconds(99))
        let forge = GitHubScaleSetForge(
            account: AccountConfig(
                name: "s", forge: .github, scope: "acme/api", scaleSet: .init(name: "kinhin-container")),
            token: "t", client: client, labels: ["self-hosted", "macos", "arm64"], listener: listener)

        let jobs = try await forge.runningJobs()

        XCTAssertEqual(jobs.map(\.name), ["build"])
        XCTAssertEqual(jobs.first?.runnerName, "kinhin-1-r1")
        XCTAssertEqual(jobs.first?.labels, ["kinhin-container"])
        XCTAssertNotNil(jobs.first?.correlation?.enqueuedAt)
    }
}
