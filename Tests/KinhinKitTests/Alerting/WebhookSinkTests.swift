import Foundation
import Synchronization
import XCTest

@testable import KinhinKit

final class WebhookSinkTests: XCTestCase {
    private final class FakeHTTP: AlertHTTP {
        struct Call {
            var url: URL
            var headers: [String: String]
            var body: Data
        }
        let calls = Mutex<[Call]>([])
        let statuses: Mutex<[Int]>

        init(statuses: [Int] = [200]) { self.statuses = Mutex(statuses) }

        func post(_ url: URL, headers: [String: String], body: Data) async throws -> Int {
            calls.withLock { $0.append(Call(url: url, headers: headers, body: body)) }
            return statuses.withLock { $0.count > 1 ? $0.removeFirst() : ($0.first ?? 200) }
        }
    }

    private let event = AlertEvent(
        source: "disk", severity: .critical, state: .firing, message: "disk is full", host: "mini",
        timestamp: Date(timeIntervalSince1970: 0))

    private func sink(_ http: FakeHTTP, format: KinhinConfig.AlertsConfig.Format = .generic, token: String? = nil)
        throws -> WebhookSink
    {
        WebhookSink(
            url: try WebhookSink.validate("https://hooks.example.com/x"), format: format, token: token, http: http,
            retryDelay: 0)
    }

    func testValidateRequiresHTTPSExceptLoopback() throws {
        XCTAssertNoThrow(try WebhookSink.validate("https://ntfy.sh/topic"))
        XCTAssertNoThrow(try WebhookSink.validate("http://localhost:8080/x"))
        XCTAssertThrowsError(try WebhookSink.validate("http://example.com/x"))
        XCTAssertThrowsError(try WebhookSink.validate("not a url"))
    }

    func testGenericBodyAndBearerHeader() async throws {
        let http = FakeHTTP()
        try await sink(http, token: "tok").send(event)
        let call = try XCTUnwrap(http.calls.withLock { $0.first })
        XCTAssertEqual(call.headers["Authorization"], "Bearer tok")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
        XCTAssertEqual(json["source"] as? String, "disk")
        XCTAssertEqual(json["state"] as? String, "firing")
    }

    func testPresetBodies() throws {
        let slack = try WebhookSink.request(for: event, format: .slack)
        XCTAssertTrue(String(decoding: slack.0, as: UTF8.self).contains("\"text\""))
        let discord = try WebhookSink.request(for: event, format: .discord)
        XCTAssertTrue(String(decoding: discord.0, as: UTF8.self).contains("\"content\""))
        let ntfy = try WebhookSink.request(for: event, format: .ntfy)
        XCTAssertEqual(ntfy.1["Title"], "kinhin")
        XCTAssertTrue(String(decoding: ntfy.0, as: UTF8.self).contains("disk is full"))
    }

    func testRetriesServerErrorsThenSucceeds() async throws {
        let http = FakeHTTP(statuses: [503, 200])
        try await sink(http).send(event)
        XCTAssertEqual(http.calls.withLock { $0.count }, 2)
    }

    func testClientErrorIsNotRetried() async {
        let http = FakeHTTP(statuses: [400])
        do {
            try await sink(http).send(event)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? AlertError, .badStatus(400))
        }
        XCTAssertEqual(http.calls.withLock { $0.count }, 1)
    }

    func testMakeSinkNeedsTheKeychainToken() throws {
        let config = KinhinConfig.AlertsConfig(
            enabled: true, webhookURL: "https://hooks.example.com/x", headersKeychain: "ops")
        XCTAssertThrowsError(try FleetEngine.makeAlertSink(config, token: { _ in nil })) {
            XCTAssertEqual($0 as? AlertError, .missingToken("ops"))
        }
        let made = try FleetEngine.makeAlertSink(config, token: { _ in "abc" })
        XCTAssertEqual(made.token, "abc")
    }
}
