import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The live pipeline view's GitHub lookup: the run's jobs with their steps,
/// the runner's own job flagged.
final class GitHubPipelineDetailTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func makeForge() -> GitHubForge {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GitHubClient(
            credentials: GitHubCredentials(token: "t", scope: "acme/widgets"),
            session: URLSession(configuration: config))
        return GitHubForge(
            credentials: .github(token: "t", scope: "acme/widgets"), labels: ["macos"], client: client)
    }

    private static func json(_ body: String) -> (Int, Data, [String: String]) { (200, Data(body.utf8), [:]) }

    func testDetailListsJobsWithStepsAndFlagsTheRunnersJob() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/actions/runs") {
                return Self.json(
                    #"{"total_count":1,"workflow_runs":[{"id":5,"head_branch":"main","head_sha":"abcdef1234567"}]}"#)
            }
            return Self.json(
                #"""
                {"total_count":2,"jobs":[
                 {"id":11,"run_id":5,"name":"build","status":"in_progress","conclusion":null,"runner_name":"kinhin-1",
                  "html_url":"https://github.com/acme/widgets/actions/runs/5/job/11","started_at":"2026-10-02T10:00:00Z",
                  "workflow_name":"CI",
                  "steps":[{"name":"Checkout","status":"completed","conclusion":"success","number":1,
                            "started_at":"2026-10-02T10:00:01Z","completed_at":"2026-10-02T10:00:05Z"},
                           {"name":"Test","status":"in_progress","conclusion":null,"number":2,
                            "started_at":"2026-10-02T10:00:06Z","completed_at":null}]},
                 {"id":12,"run_id":5,"name":"lint","status":"completed","conclusion":"failure","runner_name":"other",
                  "started_at":"2026-10-02T09:59:00Z","completed_at":"2026-10-02T09:59:40Z","steps":[]}
                ]}
                """#)
        }
        let detail = try await makeForge().pipelineDetail(runnerName: "kinhin-1", repository: nil)
        let found = try XCTUnwrap(detail)
        XCTAssertEqual(found.forge, .github)
        XCTAssertEqual(found.title, "CI")
        XCTAssertEqual(found.ref, "main")
        XCTAssertEqual(found.granularity, .step)
        XCTAssertEqual(found.jobs.map(\.name), ["build", "lint"])
        XCTAssertEqual(found.jobs.map(\.isCurrent), [true, false])
        XCTAssertEqual(found.currentJob?.steps.map(\.name), ["Checkout", "Test"])
        XCTAssertEqual(found.jobs[0].steps.map(\.state), [.succeeded, .running])
        XCTAssertEqual(found.jobs[1].state, .failed)
        XCTAssertNil(found.jobs[0].finishedAt)
        let lint = found.jobs[1]
        XCTAssertEqual(try XCTUnwrap(lint.finishedAt).timeIntervalSince(try XCTUnwrap(lint.startedAt)), 40)
        XCTAssertEqual(found.state, .running)
    }

    func testNoDetailWhenNoRunHasThisRunner() async throws {
        StubProtocol.handler = { request in
            if request.url?.path.hasSuffix("/actions/runs") == true {
                return Self.json(#"{"total_count":1,"workflow_runs":[{"id":5}]}"#)
            }
            return Self.json(
                #"{"total_count":1,"jobs":[{"id":11,"run_id":5,"name":"b","status":"in_progress","runner_name":"x"}]}"#)
        }
        let detail = try await makeForge().pipelineDetail(runnerName: "kinhin-1", repository: nil)
        XCTAssertNil(detail)
    }
}
