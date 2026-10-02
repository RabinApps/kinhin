import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The live pipeline view's Bitbucket lookup: the active pipeline's steps as
/// jobs (a step is Bitbucket's unit; its runner isn't public, so running steps
/// are all flagged).
final class BitbucketPipelineDetailTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func testDetailListsThePipelinesSteps() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/pipelines/%7Bp1%7D/steps") || path.hasSuffix("/pipelines/{p1}/steps") {
                body = #"""
                    {"values":[
                     {"uuid":"{s1}","name":"Build","state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}}},
                     {"uuid":"{s2}","name":"Test","state":{"name":"IN_PROGRESS"},"started_on":"2026-10-02T10:00:00Z"},
                     {"uuid":"{s3}","name":"Deploy","state":{"name":"PENDING"}}]}
                    """#
            } else {
                body = #"""
                    {"values":[{"uuid":"{p1}","build_number":9,"repository":{"full_name":"acme/api"},
                     "state":{"name":"IN_PROGRESS"},"target":{"ref_name":"main","commit":{"hash":"abc"}}}]}
                    """#
            }
            return (200, Data(body.utf8), [:])
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let credentials = BitbucketCredentials(token: "bbtkn", scope: "acme/api")
        let forge = BitbucketForge(
            credentials: ForgeCredentials(forge: .bitbucket, token: "bbtkn", scope: "acme/api"),
            labels: ["kinhin"],
            client: BitbucketClient(credentials: credentials, session: URLSession(configuration: config)),
            scope: BitbucketScope(credentials: credentials), workspaceUUID: "{ws-1}", repositoryUUID: nil,
            account: "bb", listTTL: 0)

        let answer = try await forge.pipelineDetail(runnerName: "kinhin-1", repository: "acme/api")
        let found = try XCTUnwrap(answer)
        XCTAssertEqual(found.title, "Pipeline #9")
        XCTAssertEqual(found.url, "https://bitbucket.org/acme/api/pipelines/results/9")
        XCTAssertEqual(found.granularity, .job)
        XCTAssertEqual(found.ref, "main")
        XCTAssertEqual(found.jobs.map(\.name), ["Build", "Test", "Deploy"])
        XCTAssertEqual(found.jobs.map(\.state), [.succeeded, .running, .pending])
        XCTAssertEqual(found.jobs.map(\.isCurrent), [false, true, false])
    }
}
