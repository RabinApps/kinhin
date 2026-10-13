import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class BuildkiteForgeTests: XCTestCase {
    private let cluster = BuildkiteCluster(id: "c-1", name: "Mac Fleet")

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeForge(labels: [String] = ["queue=kinhin", "os=macos"]) -> BuildkiteForge {
        BuildkiteForge(
            credentials: ForgeCredentials(forge: .buildkite, token: "bkua", scope: "acme/Mac Fleet"),
            labels: labels,
            client: BuildkiteClient(
                credentials: BuildkiteCredentials(token: "bkua", scope: "acme/Mac Fleet"), session: session()),
            cluster: cluster, agentToken: "bkct", account: "ci", listTTL: 0)
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Agent query rules

    func testTagsSatisfyEveryRule() {
        let tags = ["queue=kinhin", "os=macos", "xcode=16.2"]
        XCTAssertTrue(BuildkiteForge.tags(tags, satisfy: ["queue=kinhin"]))
        XCTAssertTrue(BuildkiteForge.tags(tags, satisfy: ["queue=kinhin", "os=macos"]))
        XCTAssertTrue(BuildkiteForge.tags(tags, satisfy: ["queue=kin*", "xcode=16.*"]), "* is a wildcard")
        XCTAssertFalse(BuildkiteForge.tags(tags, satisfy: ["queue=kinhin", "os=linux"]))
        XCTAssertFalse(BuildkiteForge.tags(tags, satisfy: ["queue=kinhin", "gpu=true"]), "a missing key fails")
    }

    func testJobWithoutAQueueTargetsTheDefaultQueue() {
        XCTAssertFalse(BuildkiteForge.tags(["queue=kinhin"], satisfy: []))
        XCTAssertTrue(BuildkiteForge.tags(["queue=default"], satisfy: []))
        XCTAssertTrue(BuildkiteForge.tags(["queue=default", "os=macos"], satisfy: ["os=macos"]))
    }

    func testGlobMatching() {
        XCTAssertTrue(BuildkiteForge.matches("macos-15", pattern: "macos-*"))
        XCTAssertTrue(BuildkiteForge.matches("macos-15", pattern: "*-15"))
        XCTAssertTrue(BuildkiteForge.matches("macos-15-arm", pattern: "mac*15*"))
        XCTAssertTrue(BuildkiteForge.matches("anything", pattern: "*"))
        XCTAssertFalse(BuildkiteForge.matches("linux-15", pattern: "macos-*"))
        XCTAssertFalse(BuildkiteForge.matches("macos-14", pattern: "*-15"))
    }

    func testJobsOfAnotherClusterAreNotOurs() {
        let forge = makeForge()
        let job = BuildkiteJob(
            id: "j", name: "Test", state: "scheduled", agentQueryRules: ["queue=kinhin"], pipeline: "ios",
            agentName: nil, clusterID: "c-other")
        XCTAssertFalse(forge.isOurs(job))
        XCTAssertTrue(
            forge.isOurs(
                BuildkiteJob(
                    id: "j", name: "Test", state: "scheduled", agentQueryRules: ["queue=kinhin"], pipeline: "ios",
                    agentName: nil, clusterID: nil)),
            "a job the API does not place in a cluster is judged by its rules")
    }

    // MARK: - Construction

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        func append(_ call: String) { lock.withLock { calls.append(call) } }
        var all: [String] { lock.withLock { calls } }
    }

    private func makeStub(
        queues: String = #"[{"id":"q-1","key":"kinhin"}]"#, tokens: String, calls: CallLog
    ) {
        StubProtocol.handler = { request in
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            calls.append("\(method) \(path)")
            switch (method, path) {
            case ("GET", "/v2/access-token"):
                let scopes = BuildkiteCredentials.requiredScopes.map { "\"\($0)\"" }.joined(separator: ",")
                return (200, Data(#"{"uuid":"u","scopes":[\#(scopes)]}"#.utf8), [:])
            case ("GET", "/v2/organizations/acme/clusters"):
                return (200, Data(#"[{"id":"c-1","name":"Mac Fleet"}]"#.utf8), [:])
            case ("GET", "/v2/organizations/acme/clusters/c-1/queues"):
                return (200, Data(queues.utf8), [:])
            case ("GET", "/v2/organizations/acme/clusters/c-1/tokens"):
                return (200, Data(tokens.utf8), [:])
            case ("DELETE", _):
                return (204, Data(), [:])
            case ("POST", "/v2/organizations/acme/clusters/c-1/tokens"):
                return (201, Data(#"{"id":"new","description":"x","token":"bkct_new"}"#.utf8), [:])
            default:
                return (404, Data(), [:])
            }
        }
    }

    func testMakeRevokesOnlyTokensOfDeadProcessesOfThisAccountOnThisHost() async throws {
        let calls = CallLog()
        makeStub(
            tokens: """
                [{"id":"dead","description":"kinhin: ci @ mac-1/100"},
                 {"id":"live","description":"kinhin: ci @ mac-1/200"},
                 {"id":"other-host","description":"kinhin: ci @ mac-2/100"},
                 {"id":"other-account","description":"kinhin: cd @ mac-1/100"},
                 {"id":"legacy","description":"kinhin: ci"},
                 {"id":"theirs","description":"deploy agents"}]
                """, calls: calls)
        let forge = try await BuildkiteForge.make(
            credentials: BuildkiteCredentials(token: "bkua", scope: "acme/Mac Fleet"),
            labels: BuildkiteForge.defaultLabels, account: "ci", session: session(), host: "mac-1", processID: 300,
            isProcessAlive: { $0 == 200 })

        let token = try await forge.mintRegistrationToken()
        XCTAssertEqual(token, "bkct_new")
        XCTAssertEqual(forge.cluster, cluster)
        XCTAssertEqual(forge.account, "ci")
        XCTAssertEqual(forge.registration, .sharedLongLived)
        XCTAssertEqual(
            calls.all.filter { $0.hasPrefix("DELETE") },
            ["DELETE /v2/organizations/acme/clusters/c-1/tokens/dead"],
            "a second engine's live token, other hosts' and accounts' tokens, and foreign tokens are untouched")
    }

    func testTokenDescriptionIsUniquePerProcess() {
        let one = BuildkiteForge.agentTokenDescription(account: "ci", host: "mac-1", processID: 1)
        let two = BuildkiteForge.agentTokenDescription(account: "ci", host: "mac-1", processID: 2)
        XCTAssertNotEqual(one, two)
        let owner = BuildkiteForge.tokenOwner(description: one, account: "ci")
        XCTAssertEqual(owner?.host, "mac-1")
        XCTAssertEqual(owner?.processID, 1)
        XCTAssertNil(BuildkiteForge.tokenOwner(description: one, account: "other"))
    }

    func testMakeFailsEarlyWhenTheQueueDoesNotExist() async {
        makeStub(tokens: "[]", calls: CallLog())
        do {
            _ = try await BuildkiteForge.make(
                credentials: BuildkiteCredentials(token: "bkua", scope: "acme/Mac Fleet"),
                labels: ["queue=macs"], session: session())
            XCTFail("expected queueNotFound")
        } catch BuildkiteError.queueNotFound(_, let queue, let available) {
            XCTAssertEqual(queue, "macs")
            XCTAssertEqual(available, ["kinhin"])
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testQueueDefaultsToTheClustersDefaultQueue() {
        XCTAssertEqual(BuildkiteForge.queueKey(labels: ["os=macos"]), "default")
        XCTAssertEqual(BuildkiteForge.queueKey(labels: ["queue=kinhin", "os=macos"]), "kinhin")
    }

    // MARK: - Runtime markers

    func testRuntimeRulesRouteAsMarkersAndAreNotTheAccountsToSatisfy() async throws {
        StubProtocol.handler = { _ in
            let json = #"""
                [{"pipeline":{"slug":"api"},"jobs":[
                  {"id":"j-1","type":"script","name":"Docker job","state":"scheduled",
                   "agent_query_rules":["queue=kinhin","kinhin-runtime=docker"]},
                  {"id":"j-2","type":"script","name":"Plain","state":"scheduled","agent_query_rules":["queue=kinhin"]}
                ]}]
                """#
            return (200, Data(json.utf8), [:])
        }
        let queued = try await makeForge().queuedJobs()
        XCTAssertEqual(queued.map(\.name), ["Docker job", "Plain"])
        XCTAssertEqual(queued[0].labels, ["queue=kinhin", "kinhin-docker"])
    }

    // MARK: - Build cache

    func testPipelineDetailSharesTheBuildListWithTheJobReads() async throws {
        let reads = Locked<Int>(0)
        StubProtocol.handler = { _ in
            reads.withLock { $0 += 1 }
            let json = #"""
                [{"pipeline":{"slug":"api"},"jobs":[
                  {"id":"j-1","type":"script","name":"Run","state":"running","agent_query_rules":["queue=kinhin"],
                   "agent":{"name":"kinhin-1"}}]}]
                """#
            return (200, Data(json.utf8), [:])
        }
        let forge = BuildkiteForge(
            credentials: ForgeCredentials(forge: .buildkite, token: "bkua", scope: "acme/Mac Fleet"),
            labels: ["queue=kinhin"],
            client: BuildkiteClient(
                credentials: BuildkiteCredentials(token: "bkua", scope: "acme/Mac Fleet"), session: session()),
            cluster: cluster, agentToken: "bkct", account: "ci", listTTL: 60)
        _ = try await forge.runningJobs()
        _ = try await forge.queuedJobs()
        let detail = try await forge.pipelineDetail(runnerName: "kinhin-1", repository: nil)
        XCTAssertNotNil(detail)
        XCTAssertEqual(reads.withLock { $0 }, 1, "one builds read serves every caller within the TTL")
    }

    func testMakeFailsFastOnMissingScopes() async {
        StubProtocol.handler = { _ in (200, Data(#"{"uuid":"u","scopes":["read_agents"]}"#.utf8), [:]) }
        do {
            _ = try await BuildkiteForge.make(
                credentials: BuildkiteCredentials(token: "bkua", scope: "acme/Mac Fleet"),
                labels: BuildkiteForge.defaultLabels, session: session())
            XCTFail("expected insufficientScopes")
        } catch BuildkiteError.insufficientScopes(let missing) {
            XCTAssertTrue(missing.contains("write_clusters"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Unified surface

    func testRunnersAndJobsMapToTheUnifiedShape() async throws {
        StubProtocol.handler = { request in
            switch request.url?.path {
            case "/v2/organizations/acme/agents":
                return (
                    200,
                    Data(
                        #"[{"id":"a-1","name":"kinhin-1","connection_state":"connected","job":{"id":"j-2"}},{"id":"a-2","name":"kinhin-2","connection_state":"stopping","job":null}]"#
                            .utf8), [:]
                )
            case "/v2/organizations/acme/builds":
                let json = #"""
                    [{"pipeline":{"slug":"ios-app"},"jobs":[
                      {"id":"j-1","type":"script","name":"Test","state":"scheduled","agent_query_rules":["queue=kinhin","os=macos"]},
                      {"id":"j-3","type":"script","name":"Linux","state":"scheduled","agent_query_rules":["queue=linux"]},
                      {"id":"j-2","type":"script","name":"Lint","state":"running","agent_query_rules":["queue=kinhin"],
                       "agent":{"name":"kinhin-1"}}
                    ]}]
                    """#
                return (200, Data(json.utf8), [:])
            default:
                return (404, Data(), [:])
            }
        }
        let forge = makeForge()

        let runners = try await forge.runners()
        XCTAssertEqual(
            runners,
            [
                ForgeRunner(id: "a-1", name: "kinhin-1", busy: true),
                ForgeRunner(id: "a-2", name: "kinhin-2", busy: false, online: false),
            ])
        let queued = try await forge.queuedJobs()
        XCTAssertEqual(queued.map(\.name), ["Test"], "the linux-queue job is not this fleet's")
        XCTAssertEqual(queued.first?.repository, "ios-app")
        let running = try await forge.runningJobs()
        XCTAssertEqual(running.map(\.runnerName), ["kinhin-1"])
    }

    func testDeletingARunnerStopsTheAgent() async throws {
        let stopped = Locked<[String]>([])
        StubProtocol.handler = { request in
            stopped.withLock { $0.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")") }
            return (204, Data(), [:])
        }
        try await makeForge().deleteRunner(id: "a-1")
        XCTAssertEqual(stopped.withLock { $0 }, ["PUT /v2/organizations/acme/agents/a-1/stop"])
    }
}
