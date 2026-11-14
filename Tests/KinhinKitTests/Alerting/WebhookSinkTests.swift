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

    func testRequestTimeoutIsRetried() async throws {
        let http = FakeHTTP(statuses: [408, 200])
        try await sink(http).send(event)
        XCTAssertEqual(http.calls.withLock { $0.count }, 2)
    }

    func testRedirectsAreRefused() {
        let delegate = NoRedirects()
        let url = URL(string: "https://hooks.example.com/x")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var followed: URLRequest?? = .some(URLRequest(url: url))
        delegate.urlSession(
            .shared, task: URLSession.shared.dataTask(with: url), willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: url)
        ) { followed = .some($0) }
        XCTAssertEqual(followed, .some(nil))
    }

    func testErrorsNeverEchoTheWebhookURL() {
        XCTAssertThrowsError(try WebhookSink.validate("http://example.com/hooks/SECRET-PATH?token=SECRET")) {
            XCTAssertFalse($0.localizedDescription.contains("SECRET"))
        }
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

    func testStartupFailureIsSentAsACriticalStartupAlert() async throws {
        let http = FakeHTTP()
        let config = KinhinConfig.AlertsConfig(
            enabled: true, webhooks: [.init(name: "ops", url: "https://hooks.example.com/x")])
        try await FleetEngine.sendStartupAlert(config, message: "token rejected", http: http, token: { _ in nil })
        let call = try XCTUnwrap(http.calls.withLock { $0.first })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
        XCTAssertEqual(json["source"] as? String, "startup")
        XCTAssertEqual(json["severity"] as? String, "critical")
        XCTAssertEqual(json["message"] as? String, "token rejected")
    }

    func testMakeSinkNeedsTheKeychainToken() throws {
        let webhook = KinhinConfig.AlertsConfig.Webhook(
            name: "ops", url: "https://hooks.example.com/x", headersKeychain: "ops")
        XCTAssertThrowsError(try FleetEngine.makeAlertSink(webhook, token: { _ in nil })) {
            XCTAssertEqual($0 as? AlertError, .missingToken("ops"))
        }
        let made = try FleetEngine.makeAlertSink(webhook, token: { _ in "abc" })
        XCTAssertEqual(made.token, "abc")
    }

    func testStartupAlertReachesOnlyWebhooksThatWantIt() async throws {
        let http = FakeHTTP()
        let config = KinhinConfig.AlertsConfig(
            enabled: true,
            webhooks: [
                .init(name: "all", url: "https://a.example.com/x"),
                .init(name: "disk-only", url: "https://b.example.com/x", events: [.disk]),
                .init(name: "startup", url: "https://c.example.com/x", events: [.startup]),
            ])
        try await FleetEngine.sendStartupAlert(config, message: "no forge", http: http, token: { _ in nil })
        let hosts = http.calls.withLock { $0.compactMap(\.url.host) }.sorted()
        XCTAssertEqual(hosts, ["a.example.com", "c.example.com"])
    }

    func testStartupAlertSkipsABrokenWebhookButStillReachesTheOthers() async throws {
        let http = FakeHTTP()
        let config = KinhinConfig.AlertsConfig(
            enabled: true,
            webhooks: [
                .init(name: "broken", url: "https://a.example.com/x", headersKeychain: "missing"),
                .init(name: "fine", url: "https://b.example.com/x"),
            ])
        try await FleetEngine.sendStartupAlert(config, message: "no forge", http: http, token: { _ in nil })
        XCTAssertEqual(http.calls.withLock { $0.compactMap(\.url.host) }, ["b.example.com"])
    }

    func testSendTestTargetsOneWebhookAndBypassesTheEventFilter() async throws {
        let http = FakeHTTP()
        let config = KinhinConfig.AlertsConfig(
            webhooks: [
                .init(name: "a", url: "https://a.example.com/x", events: [.disk]),
                .init(name: "b", url: "https://b.example.com/x"),
            ])
        let lines = try await AlertDelivery.sendTest(
            config, webhook: "a", now: Date(), http: http, token: { _ in nil })
        XCTAssertEqual(lines, ["test alert sent to a (https://a.example.com)"])
        XCTAssertEqual(http.calls.withLock { $0.count }, 1)
        let all = try await AlertDelivery.sendTest(config, webhook: nil, now: Date(), http: http, token: { _ in nil })
        XCTAssertEqual(all.count, 2)
    }

    func testSendTestRejectsAnUnknownNameAndAnEmptyConfig() async {
        let config = KinhinConfig.AlertsConfig(webhooks: [.init(name: "a", url: "https://a.example.com/x")])
        do {
            _ = try await AlertDelivery.sendTest(
                config, webhook: "nope", now: Date(), http: FakeHTTP(), token: { _ in nil })
            XCTFail("expected a throw")
        } catch { XCTAssertEqual(error as? AlertError, .unknownWebhook("nope")) }
        do {
            _ = try await AlertDelivery.sendTest(
                .default, webhook: nil, now: Date(), http: FakeHTTP(), token: { _ in nil })
            XCTFail("expected a throw")
        } catch { XCTAssertEqual(error as? AlertError, .notConfigured) }
    }

    func testSendTestTriesEveryWebhookAndReportsTheFailure() async {
        let http = FakeHTTP(statuses: [400, 200])
        let config = KinhinConfig.AlertsConfig(
            webhooks: [
                .init(name: "a", url: "https://a.example.com/x"), .init(name: "b", url: "https://b.example.com/x"),
            ])
        do {
            _ = try await AlertDelivery.sendTest(config, webhook: nil, now: Date(), http: http, token: { _ in nil })
            XCTFail("expected a throw")
        } catch let failure as AlertDeliveryFailure {
            XCTAssertEqual(failure.lines.count, 2)
            XCTAssertTrue(failure.lines[0].hasPrefix("a: "))
            XCTAssertTrue(failure.lines[1].hasPrefix("test alert sent to b"))
        } catch { XCTFail("\(error)") }
    }
}
