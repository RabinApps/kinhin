import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The live pipeline view's Azure DevOps lookup: the build timeline's jobs and
/// their tasks.
final class AzureDevOpsPipelineDetailTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func makeForge() -> AzureDevOpsForge {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let credentials = AzureDevOpsCredentials(
            token: "pat", scope: "Mac Fleet", instance: "https://dev.azure.com/acme/")
        return AzureDevOpsForge(
            credentials: ForgeCredentials(
                forge: .azuredevops, token: "pat", scope: "Mac Fleet", instance: "https://dev.azure.com/acme/"),
            labels: ["kinhin"],
            client: AzureDevOpsClient(credentials: credentials, session: URLSession(configuration: config)),
            pool: AzureDevOpsPool(id: 12, name: "Mac Fleet"), account: "ado", listTTL: 0)
    }

    func testDetailMapsTimelineJobsAndTasks() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/timeline") {
                body = #"""
                    {"records":[
                     {"id":"S","type":"Stage","name":"Build","state":"inProgress","order":1},
                     {"id":"J1","parentId":"S","type":"Job","name":"Compile","state":"inProgress","order":1,"workerName":"kinhin-1"},
                     {"id":"J2","parentId":"S","type":"Job","name":"Package","state":"pending","order":2},
                     {"id":"T2","parentId":"J1","type":"Task","name":"Run tests","state":"inProgress","order":2},
                     {"id":"T1","parentId":"J1","type":"Task","name":"Checkout","state":"completed","result":"succeeded","order":1}]}
                    """#
            } else if path.hasSuffix("/builds/42") {
                body =
                    #"{"buildNumber":"20261002.1","sourceBranch":"refs/heads/main","sourceVersion":"abc","definition":{"name":"iOS"},"_links":{"web":{"href":"https://dev.azure.com/acme/p/_build/results?buildId=42"}}}"#
            } else {
                body = #"""
                    {"count":1,"value":[{"requestId":1,"jobName":"Compile","assignTime":"2026-10-02T10:00:00Z",
                     "reservedAgent":{"name":"kinhin-1"},"definition":{"name":"iOS"},
                     "jobId":"J1","scopeId":"proj-1","owner":{"id":42,"name":"20261002.1"}}]}
                    """#
            }
            return (200, Data(body.utf8), [:])
        }
        let answer = try await makeForge().pipelineDetail(runnerName: "kinhin-1", repository: nil)
        let found = try XCTUnwrap(answer)
        XCTAssertEqual(found.title, "iOS #20261002.1")
        XCTAssertEqual(found.granularity, .step)
        XCTAssertEqual(found.jobs.map(\.name), ["Compile", "Package"])
        XCTAssertEqual(found.jobs.map(\.isCurrent), [true, false])
        XCTAssertEqual(found.jobs[0].steps.map(\.name), ["Checkout", "Run tests"], "tasks in order")
        XCTAssertEqual(found.jobs[0].steps.map(\.state), [.succeeded, .running])
        XCTAssertEqual(found.jobs[1].state, .pending)
    }

    func testNoDetailWhenTheRequestCarriesNoBuild() async throws {
        StubProtocol.handler = { _ in
            let body =
                #"{"count":1,"value":[{"requestId":1,"jobName":"c","assignTime":"2026-10-02T10:00:00Z","reservedAgent":{"name":"kinhin-1"}}]}"#
            return (200, Data(body.utf8), [:])
        }
        let detail = try await makeForge().pipelineDetail(runnerName: "kinhin-1", repository: nil)
        XCTAssertNil(detail)
    }
}
