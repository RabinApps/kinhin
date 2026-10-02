import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The live pipeline view's Gitea/Forgejo lookup: the running task as one job.
final class GiteaPipelineDetailTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func testDetailIsTheRunnersTask() async throws {
        StubProtocol.handler = { _ in
            let body = #"""
                {"total_count":2,"entries":[
                 {"id":7,"name":"build","status":"running","runner_name":"kinhin-1","repo_full_name":"acme/api",
                  "head_branch":"main","head_sha":"abc","url":"https://git.example.com/acme/api/actions/runs/3",
                  "display_title":"Fix bug","run_started_at":"2026-10-02T10:00:00Z"},
                 {"id":8,"name":"lint","status":"running","runner_name":"kinhin-2"}]}
                """#
            return (200, Data(body.utf8), [:])
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GiteaClient(
            credentials: GiteaCredentials(token: "fj", scope: "acme", instance: "https://git.example.com"),
            session: URLSession(configuration: config))
        let forge = GiteaForge(
            credentials: .forgejo(token: "fj", scope: "acme", instance: "https://git.example.com"),
            labels: ["macos:host"], client: client, registrationToken: "reg")

        let answer = try await forge.pipelineDetail(runnerName: "kinhin-1", repository: nil)
        let found = try XCTUnwrap(answer)
        XCTAssertEqual(found.forge, .forgejo)
        XCTAssertEqual(found.title, "Fix bug")
        XCTAssertEqual(found.granularity, .job)
        XCTAssertEqual(found.repository, "acme/api")
        XCTAssertEqual(found.jobs.map(\.name), ["build"])
        XCTAssertEqual(found.jobs.first?.isCurrent, true)
        let missing = try await forge.pipelineDetail(runnerName: "nobody", repository: nil)
        XCTAssertNil(missing)
    }
}
