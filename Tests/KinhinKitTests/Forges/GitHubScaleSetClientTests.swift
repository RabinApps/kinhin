import Foundation
import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class GitHubScaleSetClientTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func testScaleSetMessagesDecodeBatchedEventsAndStatistics() async throws {
        StubProtocol.handler = { _ in
            let json =
                #"{"messageId":42,"messageType":"RunnerScaleSetJobMessages","body":"[{\"messageType\":\"JobAssigned\",\"runnerRequestId\":17,\"repositoryName\":\"widgets\",\"ownerName\":\"acme\",\"jobDisplayName\":\"build\",\"requestLabels\":[\"linux\"]}]","statistics":{"totalAssignedJobs":3,"totalRunningJobs":1}}"#
            return (200, Data(json.utf8), [:])
        }
        let messages = try await makeClient().pollMessages(
            session: testSession(), lastMessageId: nil, maxCapacity: 7)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].messageId, "42")
        XCTAssertEqual(messages[0].statistics?.totalAssignedJobs, 3)
        XCTAssertEqual(messages[0].statistics?.activeNodesCount, 1)
        XCTAssertEqual(messages[0].events.first?.runnerRequestId, "17")
        XCTAssertEqual(messages[0].events.first?.eventType, .jobAssigned)
        XCTAssertEqual(messages[0].events.first?.repositoryName, "widgets")
    }

    func testAdminRequestUsesExchangedActionsEndpointAndJWT() async throws {
        let requests = Mutex<[URLRequest]>([])
        StubProtocol.handler = { request in
            let call = requests.withLock { captured -> Int in
                captured.append(request)
                return captured.count
            }
            switch call {
            case 1, 3:
                return (200, Data(#"{"count":0,"value":[]}"#.utf8), [:])
            case 2:
                return (200, Data(#"{"value":[{"id":1,"name":"default"}],"count":1}"#.utf8), [:])
            case 4:
                return (
                    200,
                    Data(
                        #"{"id":17,"name":"kinhin","runnerGroupName":"default","labels":[{"name":"linux","type":"System"}]}"#
                            .utf8), [:]
                )
            default:
                return (500, Data(), [:])
            }
        }
        let scaleSet = try await makeClient().ensureScaleSet(name: "kinhin", labels: ["linux"], runnerGroup: "default")
        XCTAssertEqual(scaleSet.id, 17)
        let captured = requests.withLock { $0 }
        XCTAssertEqual(captured.count, 4)
        XCTAssertEqual(captured[0].url?.host, "actions.example.invalid")
        XCTAssertEqual(captured[0].url?.path, "/prefix/_apis/runtime/runnergroups")
        let query = URLComponents(url: try XCTUnwrap(captured[0].url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(query?.contains(URLQueryItem(name: "groupName", value: "default")) == true)
        XCTAssertTrue(query?.contains(URLQueryItem(name: "api-version", value: "6.0-preview")) == true)
        XCTAssertEqual(captured[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-jwt")
        XCTAssertEqual(captured[1].url?.path, "/prefix/_apis/runtime/runnergroups")
        XCTAssertEqual(captured[1].httpMethod, "GET")
        XCTAssertEqual(captured[2].url?.path, "/prefix/_apis/runtime/runnerscalesets")
        XCTAssertEqual(captured[3].url?.path, "/prefix/_apis/runtime/runnerscalesets")
        XCTAssertEqual(captured[3].httpMethod, "POST")
        let body = try XCTUnwrap(captured[3].httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["runnerGroupId"] as? Int, 1)
        XCTAssertEqual((payload["labels"] as? [[String: String]])?.first?["type"], "System")
    }

    private func makeClient(
        instance: String? = nil,
        actionsServiceURL: URL = URL(string: "https://actions.example.invalid/prefix")!
    ) -> GitHubScaleSetClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return GitHubScaleSetClient(
            credentials: GitHubCredentials(token: "pat", scope: "acme/widgets", instance: instance),
            session: URLSession(configuration: configuration),
            adminJwtProvider: { "test-jwt" },
            actionsServiceURL: { actionsServiceURL })
    }

    func testScaleSetAdminRequestsUseTheInstanceApiBaseWhenEnterprise() async throws {
        let requests = Mutex<[URLRequest]>([])
        StubProtocol.handler = { request in
            requests.withLock { $0.append(request) }
            return (
                200,
                Data(
                    #"{"id":1,"name":"kinhin","labels":[],"statistics":{"totalAssignedJobs":0,"totalRunningJobs":0}}"#
                        .utf8), [:]
            )
        }
        let ghes = try await makeClient(instance: "https://github.example.com").scaleSetStatistics(scaleSetId: 1)
        XCTAssertEqual(ghes.totalAssignedJobs, 0)
        let captured = requests.withLock { $0 }
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].url?.host, "github.example.com")
        XCTAssertEqual(captured[0].url?.path, "/prefix/_apis/runtime/runnerscalesets/1")
    }

    func testScaleSetAdminRequestsUseGheComDataResidencyBase() async throws {
        let captured = Mutex<[URLRequest]>([])
        StubProtocol.handler = { request in
            captured.withLock { $0.append(request) }
            switch captured.withLock { $0.count } {
            case 1, 3:
                return (200, Data(#"{"count":0,"value":[]}"#.utf8), [:])
            case 2:
                return (200, Data(#"{"value":[{"id":1,"name":"default"}],"count":1}"#.utf8), [:])
            case 4:
                return (
                    200,
                    Data(
                        #"{"id":9,"name":"kinhin-2","labels":[{"name":"linux","type":"System"}],"statistics":{"totalAssignedJobs":0,"totalRunningJobs":0}}"#
                            .utf8), [:]
                )
            default:
                return (500, Data(), [:])
            }
        }
        let residency = try await makeClient(instance: "https://acme.ghe.com").ensureScaleSet(
            name: "kinhin-2", labels: ["linux"], runnerGroup: "default")
        XCTAssertEqual(residency.id, 9)
        let reqs = captured.withLock { $0 }
        XCTAssertEqual(reqs.count, 4)
        XCTAssertEqual(reqs[0].url?.host, "api.acme.ghe.com")
        XCTAssertEqual(reqs[1].url?.host, "api.acme.ghe.com")
        XCTAssertEqual(reqs[2].url?.host, "api.acme.ghe.com")
        XCTAssertEqual(reqs[3].url?.host, "api.acme.ghe.com")
        XCTAssertEqual(reqs[3].url?.path, "/prefix/_apis/runtime/runnerscalesets")
        XCTAssertEqual(reqs[3].httpMethod, "POST")
        let body = try XCTUnwrap(reqs[3].httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["runnerGroupId"] as? Int, 1)
    }

    func testScaleSetAdminRequestsUseGheComDataResidencyBaseWhenActionsServiceURLIsSet() async throws {
        let captured = Mutex<[URLRequest]>([])
        let actionsURL = URL(string: "https://actions.acme.ghe.com/a/_apis/runtime")!
        StubProtocol.handler = { request in
            captured.withLock { $0.append(request) }
            switch captured.withLock { $0.count } {
            case 1, 3:
                return (200, Data(#"{"count":0,"value":[]}"#.utf8), [:])
            case 2:
                return (200, Data(#"{"value":[{"id":1,"name":"default"}],"count":1}"#.utf8), [:])
            case 4:
                return (
                    200,
                    Data(
                        #"{"id":7,"name":"kinhin","labels":[{"name":"linux","type":"System"}],"statistics":{"totalAssignedJobs":0,"totalRunningJobs":0}}"#
                            .utf8), [:]
                )
            default:
                return (500, Data(), [:])
            }
        }
        let residency = try await makeClient(instance: "https://acme.ghe.com", actionsServiceURL: actionsURL)
            .ensureScaleSet(name: "kinhin", labels: ["linux"], runnerGroup: "default")
        XCTAssertEqual(residency.id, 7)
        let reqs = captured.withLock { $0 }
        XCTAssertEqual(reqs.count, 4)
        XCTAssertEqual(reqs[0].url?.host, "actions.acme.ghe.com")
        XCTAssertEqual(reqs[0].url?.path, "/a/_apis/runtime/runnergroups")
        XCTAssertEqual(reqs[1].url?.host, "api.acme.ghe.com")
        XCTAssertEqual(reqs[2].url?.host, "api.acme.ghe.com")
        XCTAssertEqual(reqs[3].url?.host, "api.acme.ghe.com")
        XCTAssertEqual(reqs[3].url?.path, "/a/_apis/runtime/runnerscalesets")
        XCTAssertEqual(reqs[3].httpMethod, "POST")
        let body = try XCTUnwrap(reqs[3].httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["runnerGroupId"] as? Int, 1)
    }

    func testStatisticsLoadsScaleSetById() async throws {
        let requests = Mutex<[URLRequest]>([])
        StubProtocol.handler = { request in
            requests.withLock { $0.append(request) }
            let body =
                #"{"id":17,"name":"kinhin","labels":[],"statistics":{"totalAssignedJobs":4,"totalRunningJobs":2}}"#
            return (200, Data(body.utf8), [:])
        }
        let statistics = try await makeClient().scaleSetStatistics(scaleSetId: 17)
        XCTAssertEqual(statistics.totalAssignedJobs, 4)
        XCTAssertEqual(statistics.activeNodesCount, 2)
        let request = try XCTUnwrap(requests.withLock { $0.first })
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/prefix/_apis/runtime/runnerscalesets/17")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(query?.contains(URLQueryItem(name: "api-version", value: "6.0-preview")) == true)
    }

    func testMessageQueueUsesCapacityAndAcknowledgesWithMessageId() async throws {
        let requests = Mutex<[URLRequest]>([])
        StubProtocol.handler = { request in
            requests.withLock { $0.append(request) }
            if request.httpMethod == "GET" {
                let json =
                    #"{"messageId":9,"messageType":"RunnerScaleSetJobMessages","body":"[]","statistics":{"totalAssignedJobs":0,"totalRunningJobs":0}}"#
                return (200, Data(json.utf8), [:])
            }
            return (204, Data(), [:])
        }
        let session = testSession()
        let client = makeClient()
        let messages = try await client.pollMessages(session: session, lastMessageId: "8", maxCapacity: 12)
        XCTAssertEqual(messages.first?.messageId, "9")
        XCTAssertEqual(messages.first?.statistics?.totalAssignedJobs, 0)
        try await client.ackMessage(session: session, messageId: "9")
        let captured = requests.withLock { $0 }
        XCTAssertEqual(captured[0].value(forHTTPHeaderField: "X-ScaleSetMaxCapacity"), "12")
        XCTAssertEqual(captured[0].value(forHTTPHeaderField: "Authorization"), "Bearer queue-token")
        let query = URLComponents(url: try XCTUnwrap(captured[0].url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(query?.contains(URLQueryItem(name: "lastMessageId", value: "8")) == true)
        XCTAssertEqual(captured[1].url?.path, "/messages/9")
        XCTAssertEqual(captured[1].httpMethod, "DELETE")
    }

    private func testSession() -> GitHubScaleSetSession {
        GitHubScaleSetSession(
            sessionId: "session-1", messageQueueUrl: URL(string: "https://queue.example.invalid/messages")!,
            messageQueueAccessToken: "queue-token")
    }
}
