import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class AzureDevOpsForgeTests: XCTestCase {
    private let pool = AzureDevOpsPool(id: 12, name: "Mac Fleet")

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeForge(labels: [String] = ["kinhin"]) -> AzureDevOpsForge {
        let credentials = AzureDevOpsCredentials(
            token: "pat", scope: "Mac Fleet", instance: "https://dev.azure.com/acme/")
        return AzureDevOpsForge(
            credentials: ForgeCredentials(
                forge: .azuredevops, token: "pat", scope: "Mac Fleet", instance: "https://dev.azure.com/acme/"),
            labels: labels, client: AzureDevOpsClient(credentials: credentials, session: session()), pool: pool,
            account: "ado", listTTL: 0)
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Demands

    func testDemandsMustAskForEveryLabel() {
        XCTAssertTrue(AzureDevOpsForge.demands(["kinhin", "Agent.Version -gtVersion 3.0"], include: ["kinhin"]))
        XCTAssertTrue(AzureDevOpsForge.demands(["Kinhin -equals true"], include: ["kinhin"]), "names ignore case")
        XCTAssertTrue(AzureDevOpsForge.demands(["xcode -equals 16"], include: ["xcode=16"]))
        XCTAssertFalse(AzureDevOpsForge.demands(["xcode -equals 15"], include: ["xcode=16"]))
        XCTAssertFalse(AzureDevOpsForge.demands(["xcode"], include: ["xcode=16"]), "a value label needs -equals")
        XCTAssertFalse(AzureDevOpsForge.demands(["Agent.Version -gtVersion 3.0"], include: ["kinhin"]))
        XCTAssertTrue(AzureDevOpsForge.demands([], include: []), "no labels: the whole pool is kinhin's")
    }

    func testLabelsBecomeCapabilityEnvironment() {
        XCTAssertEqual(AzureDevOpsForge.capabilityEnvironment(["kinhin", "xcode=16"]), ["kinhin=true", "xcode=16"])
    }

    // MARK: - Construction

    func testMakeResolvesThePoolAndRegistersWithThePAT() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"count":1,"value":[{"id":12,"name":"Mac Fleet"}]}"#.utf8), [:]) }
        let forge = try await AzureDevOpsForge.make(
            credentials: AzureDevOpsCredentials(
                token: "pat", scope: "Mac Fleet", instance: "https://dev.azure.com/acme/"),
            labels: [], account: "ado", session: session())
        XCTAssertEqual(forge.pool, pool)
        XCTAssertEqual(forge.account, "ado")
        XCTAssertEqual(forge.registrationURL(), "https://dev.azure.com/acme", "trailing slash trimmed")
        let token = try await forge.mintRegistrationToken()
        XCTAssertEqual(token, "pat")
        XCTAssertEqual(forge.exitSemantics, .deregisters)
    }

    // MARK: - Unified surface

    func testRunnersAndJobsMapToTheUnifiedShape() async throws {
        StubProtocol.handler = { request in
            if request.url?.path.hasSuffix("/agents") == true {
                return (
                    200,
                    Data(
                        #"{"count":2,"value":[{"id":1,"name":"kinhin-1","status":"online","assignedRequest":{"requestId":2}},{"id":2,"name":"kinhin-2","status":"offline"}]}"#
                            .utf8), [:]
                )
            }
            let json = #"""
                {"count":3,"value":[
                  {"requestId":1,"jobName":"Build","demands":["kinhin"],"definition":{"name":"ios-app"}},
                  {"requestId":3,"jobName":"Other","demands":["linux"],"definition":{"name":"server"}},
                  {"requestId":2,"jobName":"Test","assignTime":"2026-09-30T10:00:00Z","demands":["kinhin"],
                   "reservedAgent":{"name":"kinhin-1"},"definition":{"name":"ios-app"}}
                ]}
                """#
            return (200, Data(json.utf8), [:])
        }
        let forge = makeForge()

        let runners = try await forge.runners()
        XCTAssertEqual(
            runners,
            [
                ForgeRunner(id: "1", name: "kinhin-1", busy: true),
                ForgeRunner(id: "2", name: "kinhin-2", busy: false, online: false),
            ])
        let queued = try await forge.queuedJobs()
        XCTAssertEqual(queued.map(\.name), ["Build"], "a job that doesn't demand kinhin is not this fleet's")
        XCTAssertEqual(queued.first?.repository, "ios-app")
        let running = try await forge.runningJobs()
        XCTAssertEqual(running.map(\.runnerName), ["kinhin-1"])
    }

    func testDeletingARunnerDeletesTheAgent() async throws {
        let calls = Mutex<[String]>([])
        StubProtocol.handler = { request in
            calls.withLock { $0.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")") }
            return (204, Data(), [:])
        }
        try await makeForge().deleteRunner(id: "7")
        XCTAssertEqual(calls.withLock { $0 }, ["DELETE /acme/_apis/distributedtask/pools/12/agents/7"])
    }
}
