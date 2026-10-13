import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The live pipeline view's GitLab lookup: the pipeline's jobs (job-level; the
/// API has no steps below a job), the runner's own job flagged.
final class GitLabPipelineDetailTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func testDetailListsThePipelinesJobs() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/projects/7/pipelines/55/jobs") {
                body =
                    #"[{"id":2,"name":"test","stage":"test","status":"running","runner":{"description":"kinhin-1"}},"#
                    + #"{"id":1,"name":"build","stage":"build","status":"success","started_at":"2026-10-02T10:00:00Z","finished_at":"2026-10-02T10:01:00Z"}]"#
            } else if path.hasSuffix("/projects/7/pipelines/55") {
                body =
                    #"{"id":55,"status":"running","ref":"main","sha":"abc","web_url":"https://gitlab.com/acme/api/-/pipelines/55"}"#
            } else {
                body =
                    #"[{"id":2,"name":"test","tag_list":["macos"],"runner":{"description":"kinhin-1"},"#
                    + #""pipeline":{"id":55}}]"#
            }
            return (200, Data(body.utf8), [:])
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GitLabClient(
            credentials: GitLabCredentials(token: "glpat", scope: "acme/api"),
            session: URLSession(configuration: config))
        let forge = GitLabForge(
            credentials: .gitlab(token: "glpat", scope: "acme/api", instance: GitLabCredentials.defaultInstance),
            labels: ["macos"], client: client, scope: .project(id: 7, path: "acme/api"), runnerListTTL: 0)

        let answer = try await forge.pipelineDetail(runnerName: "kinhin-1", repository: nil)
        let found = try XCTUnwrap(answer)
        XCTAssertEqual(found.forge, .gitlab)
        XCTAssertEqual(found.title, "Pipeline #55")
        XCTAssertEqual(found.granularity, .job)
        XCTAssertEqual(found.url, "https://gitlab.com/acme/api/-/pipelines/55")
        XCTAssertEqual(found.jobs.map(\.name), ["build › build", "test › test"], "ordered by job id, stage shown")
        XCTAssertEqual(found.jobs.map(\.isCurrent), [false, true])
        XCTAssertEqual(found.jobs.map(\.state), [.succeeded, .running])
        XCTAssertTrue(found.jobs.allSatisfy { $0.steps.isEmpty })
    }

    /// The engine's own running-jobs poll already read every project; the
    /// detail view reuses it instead of fanning out again.
    func testDetailReusesTheRecentRunningJobsRead() async throws {
        let runningReads = Locked(0)
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/pipelines/55/jobs") {
                body = #"[{"id":2,"name":"test","stage":"test","status":"running"}]"#
            } else if path.hasSuffix("/pipelines/55") {
                body = #"{"id":55,"status":"running","ref":"main","sha":"abc"}"#
            } else {
                runningReads.withLock { $0 += 1 }
                body =
                    #"[{"id":2,"name":"test","tag_list":["macos"],"runner":{"description":"kinhin-1"},"pipeline":{"id":55}}]"#
            }
            return (200, Data(body.utf8), [:])
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GitLabClient(
            credentials: GitLabCredentials(token: "glpat", scope: "acme/api"),
            session: URLSession(configuration: config))
        let forge = GitLabForge(
            credentials: .gitlab(token: "glpat", scope: "acme/api", instance: GitLabCredentials.defaultInstance),
            labels: ["macos"], client: client, scope: .project(id: 7, path: "acme/api"), runnerListTTL: 0)

        _ = try await forge.runningJobs()
        XCTAssertEqual(runningReads.withLock { $0 }, 1)
        _ = try await forge.pipelineDetail(runnerName: "kinhin-1", repository: nil)
        _ = try await forge.pipelineDetail(runnerName: "kinhin-1", repository: nil)
        XCTAssertEqual(runningReads.withLock { $0 }, 1, "served from the poll's result")

        // A runner the cached read does not know forces one fresh read.
        _ = try await forge.pipelineDetail(runnerName: "kinhin-2", repository: nil)
        XCTAssertEqual(runningReads.withLock { $0 }, 2)
    }
}
