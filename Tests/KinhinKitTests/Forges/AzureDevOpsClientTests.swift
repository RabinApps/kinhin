import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class AzureDevOpsClientTests: XCTestCase {
    private let pool = AzureDevOpsPool(id: 12, name: "Mac Fleet")

    private func makeClient(pool: String = "Mac Fleet", instance: String = "https://dev.azure.com/acme")
        -> AzureDevOpsClient
    {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return AzureDevOpsClient(
            credentials: AzureDevOpsCredentials(token: "pat", scope: pool, instance: instance),
            session: URLSession(configuration: config))
    }

    private static func json(_ body: String) -> (Int, Data, [String: String]) {
        (200, Data(body.utf8), ["Content-Type": "application/json; charset=utf-8"])
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Credentials and URLs

    func testInstanceScopeAndLabelValidation() {
        XCTAssertNoThrow(try AzureDevOpsCredentials.validate(instance: "https://dev.azure.com/acme"))
        XCTAssertNoThrow(try AzureDevOpsCredentials.validate(instance: "https://tfs.example.com/tfs/DefaultCollection"))
        XCTAssertThrowsError(try AzureDevOpsCredentials.validate(instance: "dev.azure.com/acme"))
        XCTAssertThrowsError(try AzureDevOpsCredentials.validate(instance: "https://dev.azure.com/acme/_apis"))
        XCTAssertTrue(AzureDevOpsCredentials.isValidScope("Mac Fleet"))
        XCTAssertFalse(AzureDevOpsCredentials.isValidScope("  "))
        XCTAssertTrue(AzureDevOpsCredentials.isValidLabel("kinhin"))
        XCTAssertTrue(AzureDevOpsCredentials.isValidLabel("xcode=16"))
        XCTAssertFalse(AzureDevOpsCredentials.isValidLabel("1kinhin"), "environment names can't start with a digit")
        XCTAssertFalse(AzureDevOpsCredentials.isValidLabel("macos:host"))
    }

    func testURLsKeepTheCollectionPathAndPinTheAPIVersion() throws {
        let url = try makeClient(instance: "https://tfs.example.com/tfs/DefaultCollection/").url(
            "/_apis/distributedtask/pools", [URLQueryItem(name: "poolName", value: "Mac Fleet")])
        XCTAssertEqual(
            url.absoluteString,
            "https://tfs.example.com/tfs/DefaultCollection/_apis/distributedtask/pools?poolName=Mac%20Fleet&api-version=7.0"
        )
    }

    func testSendsThePATAsBasicAuth() async throws {
        StubProtocol.handler = { request in
            let expected = "Basic " + Data(":pat".utf8).base64EncodedString()
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expected)
            return (200, Data(#"{"count":1,"value":[{"id":12,"name":"Mac Fleet"}]}"#.utf8), [:])
        }
        let resolved = try await makeClient().resolvePool()
        XCTAssertEqual(resolved, pool)
    }

    // MARK: - Pools

    func testPoolTheTokenCanOnlySeeIsNotManageable() async {
        StubProtocol.handler = { request in
            let manage = request.url?.query?.contains("actionFilter=manage") == true
            return (
                200,
                Data(
                    (manage ? #"{"count":0,"value":[]}"# : #"{"count":1,"value":[{"id":12,"name":"Mac Fleet"}]}"#).utf8),
                [:]
            )
        }
        do {
            _ = try await makeClient().resolvePool()
            XCTFail("expected cannotManagePool")
        } catch let error as AzureDevOpsError {
            XCTAssertEqual(error, .cannotManagePool("Mac Fleet"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testMissingPoolIsNamed() async {
        StubProtocol.handler = { _ in (200, Data(#"{"count":0,"value":[]}"#.utf8), [:]) }
        do {
            _ = try await makeClient().resolvePool()
            XCTFail("expected poolNotFound")
        } catch let error as AzureDevOpsError {
            XCTAssertEqual(error, .poolNotFound("Mac Fleet"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testASignInPageMeansTheTokenWasRejected() async {
        for (status, headers) in [(203, [String: String]()), (200, ["Content-Type": "text/html; charset=utf-8"])] {
            StubProtocol.handler = { _ in (status, Data("<html>Sign in</html>".utf8), headers) }
            do {
                _ = try await makeClient().resolvePool()
                XCTFail("expected unauthorized for \(status)")
            } catch let error as ForgeAPIError {
                XCTAssertEqual(error, .unauthorized(forge: .azuredevops))
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    /// A bad PAT can redirect to the sign-in host. The session refuses a cross-host hop, so the 3xx itself arrives:
    /// that is a rejected token, not an outage worth retrying.
    func testARedirectToTheSignInHostMeansTheTokenWasRejected() async {
        for status in [301, 302, 303, 307, 308] {
            StubProtocol.handler = { _ in
                (status, Data(), ["Location": "https://app.vssps.visualstudio.com/_signin?realm=dev.azure.com"])
            }
            do {
                _ = try await makeClient().resolvePool()
                XCTFail("expected unauthorized for \(status)")
            } catch let error as ForgeAPIError {
                XCTAssertEqual(error, .unauthorized(forge: .azuredevops), "status \(status)")
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    // MARK: - Agents

    func testListsAgentsWithTheirAssignedRequest() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/acme/_apis/distributedtask/pools/12/agents")
            XCTAssertTrue(request.url?.query?.contains("includeAssignedRequest=true") == true)
            return Self.json(
                #"{"count":2,"value":[{"id":1,"name":"kinhin-1","status":"online","assignedRequest":{"requestId":55}},{"id":2,"name":"kinhin-2","status":"offline"}]}"#
            )
        }
        let agents = try await makeClient().listAgents(pool: pool)
        XCTAssertEqual(agents.map(\.name), ["kinhin-1", "kinhin-2"])
        XCTAssertEqual(agents.map(\.busy), [true, false])
        XCTAssertEqual(agents.map(\.status), ["online", "offline"])
    }

    func testDeletingAnAgentThatIsGoneSucceeds() async throws {
        let calls = Locked<[String]>([])
        StubProtocol.handler = { request in
            calls.withLock { $0.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")") }
            return (404, Data(), [:])
        }
        try await makeClient().deleteAgent(pool: pool, id: 7)
        XCTAssertEqual(calls.withLock { $0 }, ["DELETE /acme/_apis/distributedtask/pools/12/agents/7"])
    }

    // MARK: - Job requests

    func testJobRequestsKeepQueuedAndRunningOnes() async throws {
        StubProtocol.handler = { _ in
            Self.json(
                #"""
                {"count":3,"value":[
                  {"requestId":1,"jobName":"Build","demands":["kinhin","Agent.Version -gtVersion 3.0"],
                   "definition":{"id":4,"name":"ios-app"}},
                  {"requestId":2,"jobName":"Test","assignTime":"2026-09-30T10:00:00Z","demands":[{"name":"kinhin"}],
                   "reservedAgent":{"id":1,"name":"kinhin-1"},"definition":{"id":4,"name":"ios-app"}},
                  {"requestId":3,"jobName":"Old","assignTime":"2026-09-30T09:00:00Z","result":"succeeded",
                   "finishTime":"2026-09-30T09:10:00Z"}
                ]}
                """#)
        }
        let requests = try await makeClient().jobRequests(pool: pool)
        XCTAssertEqual(requests.map(\.requestId), [1, 2], "finished requests are left out")
        XCTAssertEqual(requests.map(\.isQueued), [true, false])
        XCTAssertEqual(requests.map(\.isRunning), [false, true])
        XCTAssertEqual(requests.first?.demands, ["kinhin", "Agent.Version -gtVersion 3.0"])
        XCTAssertEqual(requests.last?.demands, ["kinhin"], "object demands decode too")
        XCTAssertEqual(requests.last?.reservedAgent?.name, "kinhin-1")
        XCTAssertEqual(requests.first?.pipeline, "ios-app")
    }

    // MARK: - Errors

    func testTransienceAndCategory() {
        XCTAssertTrue(ForgeTransport.isTransient(ForgeAPIError.http(forge: .azuredevops, code: 503, body: "")))
        XCTAssertFalse(ForgeTransport.isTransient(ForgeAPIError.http(forge: .azuredevops, code: 400, body: "")))
        XCTAssertFalse(ForgeTransport.isTransient(ForgeAPIError.unauthorized(forge: .azuredevops)))
        XCTAssertEqual(ErrorCategory(ForgeAPIError.unauthorized(forge: .azuredevops)), .auth)
    }
}
