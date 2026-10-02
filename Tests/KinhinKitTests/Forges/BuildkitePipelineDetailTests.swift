import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The live pipeline view's Buildkite lookup: the build's script jobs.
final class BuildkitePipelineDetailTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func testDetailListsTheBuildsScriptJobs() async throws {
        StubProtocol.handler = { _ in
            let body = #"""
                [{"pipeline":{"slug":"ios","name":"iOS"},"number":88,"state":"running","branch":"main","commit":"abc123",
                  "web_url":"https://buildkite.com/acme/ios/builds/88","started_at":"2026-10-02T10:00:00Z",
                  "jobs":[
                   {"id":"j1","type":"script","name":"Build","state":"passed","agent":{"name":"kinhin-0"}},
                   {"id":"j2","type":"script","name":"Test","state":"running","agent":{"name":"kinhin-1"}},
                   {"id":"w","type":"waiter","state":"waiting"}]}]
                """#
            return (200, Data(body.utf8), [:])
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let forge = BuildkiteForge(
            credentials: ForgeCredentials(forge: .buildkite, token: "bkua", scope: "acme/Mac Fleet"),
            labels: ["queue=kinhin"],
            client: BuildkiteClient(
                credentials: BuildkiteCredentials(token: "bkua", scope: "acme/Mac Fleet"),
                session: URLSession(configuration: config)),
            cluster: BuildkiteCluster(id: "c-1", name: "Mac Fleet"), agentToken: "bkct", account: "ci", listTTL: 0)

        let answer = try await forge.pipelineDetail(runnerName: "kinhin-1", repository: nil)
        let found = try XCTUnwrap(answer)
        XCTAssertEqual(found.title, "iOS #88")
        XCTAssertEqual(found.granularity, .job)
        XCTAssertEqual(found.ref, "main")
        XCTAssertEqual(found.jobs.map(\.name), ["Build", "Test"], "the waiter is not a job")
        XCTAssertEqual(found.jobs.map(\.state), [.succeeded, .running])
        XCTAssertEqual(found.currentJob?.name, "Test")
    }
}
