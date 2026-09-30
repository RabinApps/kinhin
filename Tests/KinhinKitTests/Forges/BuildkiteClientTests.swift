import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class BuildkiteClientTests: XCTestCase {
    private func makeClient(scope: String = "acme/Mac Fleet") -> BuildkiteClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return BuildkiteClient(
            credentials: BuildkiteCredentials(token: "bkua", scope: scope),
            session: URLSession(configuration: config))
    }

    private let cluster = BuildkiteCluster(id: "c-1", name: "Mac Fleet")

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Scope and URLs

    func testScopeIsOrgSlugAndCluster() {
        XCTAssertTrue(BuildkiteCredentials.isValidScope("acme/Mac Fleet"))
        XCTAssertTrue(BuildkiteCredentials.isValidScope("acme-inc/3f6c1f0e-1d7a-4d3a-9d8e-0b5a9f2c7e11"))
        XCTAssertFalse(BuildkiteCredentials.isValidScope("acme"), "the cluster is required")
        XCTAssertFalse(BuildkiteCredentials.isValidScope("acme/ "))
        XCTAssertFalse(BuildkiteCredentials.isValidScope("Acme/default"), "org slugs are lowercase")
        let credentials = BuildkiteCredentials(token: "t", scope: "acme/Mac Fleet")
        XCTAssertEqual(credentials.organization, "acme")
        XCTAssertEqual(credentials.cluster, "Mac Fleet")
    }

    func testSendsBearerTokenToTheV2API() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.buildkite.com/v2/access-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bkua")
            return (200, Data(#"{"uuid":"u","scopes":["read_agents","read_builds"]}"#.utf8), [:])
        }
        let scopes = try await makeClient().tokenScopes()
        XCTAssertEqual(scopes, ["read_agents", "read_builds"])
    }

    func testMissingScopesAreNamed() async {
        StubProtocol.handler = { _ in
            (200, Data(#"{"uuid":"u","scopes":["read_agents","write_agents","read_builds"]}"#.utf8), [:])
        }
        do {
            try await makeClient().verifyScopes()
            XCTFail("expected insufficientScopes")
        } catch let error as BuildkiteError {
            XCTAssertEqual(error, .insufficientScopes(["read_clusters", "write_clusters"]))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Clusters

    func testResolvesAClusterByNameOrID() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v2/organizations/acme/clusters")
            return (200, Data(#"[{"id":"c-0","name":"Default"},{"id":"c-1","name":"Mac Fleet"}]"#.utf8), [:])
        }
        let byName = try await makeClient(scope: "acme/mac fleet").resolveCluster()
        XCTAssertEqual(byName, cluster, "names match case-insensitively")
        let byID = try await makeClient(scope: "acme/c-1").resolveCluster()
        XCTAssertEqual(byID, cluster)
    }

    func testUnknownClusterIsNamed() async {
        StubProtocol.handler = { _ in (200, Data(#"[{"id":"c-0","name":"Default"}]"#.utf8), [:]) }
        do {
            _ = try await makeClient().resolveCluster()
            XCTFail("expected clusterNotFound")
        } catch let error as BuildkiteError {
            XCTAssertEqual(error, .clusterNotFound(organization: "acme", cluster: "Mac Fleet"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testListScopesPairsEveryOrgWithItsClusters() async throws {
        StubProtocol.handler = { request in
            switch request.url?.path {
            case "/v2/organizations":
                return (200, Data(#"[{"slug":"acme"},{"slug":"labs"}]"#.utf8), [:])
            case "/v2/organizations/acme/clusters":
                return (200, Data(#"[{"id":"c-1","name":"Mac Fleet"}]"#.utf8), [:])
            case "/v2/organizations/labs/clusters":
                return (200, Data(#"[{"id":"c-2","name":"default"}]"#.utf8), [:])
            default:
                return (404, Data(), [:])
            }
        }
        let scopes = try await makeClient().listScopes()
        XCTAssertEqual(scopes.map(\.fullName), ["acme/Mac Fleet", "labs/default"])
    }

    // MARK: - Agent tokens

    func testCreatesAnAgentTokenAndReturnsItsValue() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v2/organizations/acme/clusters/c-1/tokens")
            let body = try? JSONSerialization.jsonObject(with: request.bodyStreamData()) as? [String: String]
            XCTAssertEqual(body?["description"], "kinhin: work")
            return (201, Data(#"{"id":"t-9","description":"kinhin: work","token":"bkct_secret"}"#.utf8), [:])
        }
        let token = try await makeClient().createAgentToken(cluster: cluster, description: "kinhin: work")
        XCTAssertEqual(token.id, "t-9")
        XCTAssertEqual(token.token, "bkct_secret")
    }

    func testAgentTokenWithoutAValueIsAnError() async {
        StubProtocol.handler = { _ in (201, Data(#"{"id":"t-9","description":"kinhin: work"}"#.utf8), [:]) }
        do {
            _ = try await makeClient().createAgentToken(cluster: cluster, description: "kinhin: work")
            XCTFail("a token without its value cannot register agents")
        } catch let error as BuildkiteError {
            guard case .decoding = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Agents

    func testListsAgentsAcrossPages() async throws {
        let page2 = "https://api.buildkite.com/v2/organizations/acme/agents?page=2&per_page=100"
        StubProtocol.handler = { request in
            if request.url?.query?.contains("page=2") == true {
                return (200, Data(#"[{"id":"a-2","name":"vm-2","connection_state":"connected","job":null}]"#.utf8), [:])
            }
            return (
                200,
                Data(
                    #"[{"id":"a-1","name":"vm-1","connection_state":"connected","job":{"id":"j-1"},"meta_data":["queue=kinhin"]}]"#
                        .utf8),
                ["Link": "<\(page2)>; rel=\"next\", <\(page2)>; rel=\"last\""]
            )
        }
        let agents = try await makeClient().listAgents()
        XCTAssertEqual(agents.map(\.name), ["vm-1", "vm-2"])
        XCTAssertEqual(agents.map(\.busy), [true, false])
        XCTAssertEqual(agents.first?.metaData, ["queue=kinhin"])
    }

    func testStoppingADisconnectedAgentSucceeds() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/v2/organizations/acme/agents/a-1/stop")
            return (400, Data(#"{"message":"Agent is not connected"}"#.utf8), [:])
        }
        try await makeClient().stopAgent(id: "a-1")
    }

    // MARK: - Jobs

    func testActiveJobsKeepScriptStepsWithTheirPipeline() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v2/organizations/acme/builds")
            let states = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .filter { $0.name == "state[]" }.compactMap(\.value)
            XCTAssertEqual(states, ["scheduled", "running", "failing"])
            let json = #"""
                [{"pipeline":{"slug":"ios-app"},"jobs":[
                  {"id":"j-1","type":"script","name":"Test","state":"scheduled","agent_query_rules":["queue=kinhin"]},
                  {"id":"w-1","type":"waiter"},
                  {"id":"j-2","type":"script","name":"Lint","state":"running","agent_query_rules":["queue=kinhin"],
                   "agent":{"name":"vm-1"},"cluster_id":"c-1"}
                ]}]
                """#
            return (200, Data(json.utf8), [:])
        }
        let jobs = try await makeClient().activeJobs()
        XCTAssertEqual(jobs.map(\.id), ["j-1", "j-2"], "the waiter step carries no agent demand")
        XCTAssertEqual(jobs.map(\.pipeline), ["ios-app", "ios-app"])
        XCTAssertEqual(jobs.map(\.isQueued), [true, false])
        XCTAssertEqual(jobs.map(\.isRunning), [false, true])
        XCTAssertEqual(jobs.last?.agentName, "vm-1")
        XCTAssertEqual(jobs.last?.clusterID, "c-1")
    }

    // MARK: - Errors and plumbing

    func testStatusCodesMapToErrors() async {
        for (status, expected) in [(401, BuildkiteError.unauthorized), (404, .notFound("/v2/access-token"))] {
            StubProtocol.handler = { _ in (status, Data(), [:]) }
            do {
                _ = try await makeClient().tokenScopes()
                XCTFail("expected \(expected)")
            } catch let error as BuildkiteError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func testNextPageParsing() {
        XCTAssertEqual(
            BuildkiteClient.nextPage(
                #"<https://api.buildkite.com/v2/x?page=3>; rel="next", <https://a/b>; rel="last""#),
            URL(string: "https://api.buildkite.com/v2/x?page=3"))
        XCTAssertNil(BuildkiteClient.nextPage(#"<https://a/b?page=1>; rel="prev""#))
        XCTAssertNil(BuildkiteClient.nextPage(nil))
    }

    func testTransienceAndCategory() {
        XCTAssertTrue(BuildkiteClient.isTransient(BuildkiteError.http(503, "")))
        XCTAssertTrue(BuildkiteClient.isTransient(BuildkiteError.http(429, "")))
        XCTAssertFalse(BuildkiteClient.isTransient(BuildkiteError.http(400, "")))
        XCTAssertFalse(BuildkiteClient.isTransient(BuildkiteError.unauthorized))
        XCTAssertEqual(ErrorCategory(BuildkiteError.unauthorized), .auth)
    }
}

extension URLRequest {
    /// URLProtocol receives POST bodies as a stream; read it back for asserts.
    fileprivate func bodyStreamData() -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
