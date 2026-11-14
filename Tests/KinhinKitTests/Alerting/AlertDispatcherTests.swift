import Foundation
import Synchronization
import XCTest

@testable import KinhinKit

final class FakeAlertSink: AlertSink {
    private let events = Mutex<[AlertEvent]>([])
    private let failingFlag = Mutex(false)
    var failing: Bool {
        get { failingFlag.withLock { $0 } }
        set { failingFlag.withLock { $0 = newValue } }
    }
    var sent: [AlertEvent] { events.withLock { $0 } }

    struct Down: Error {}

    func send(_ event: AlertEvent) async throws {
        events.withLock { $0.append(event) }
        if failing { throw Down() }
    }
}

final class AlertDispatcherTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func make(
        _ sink: FakeAlertSink, policy: AlertDispatcher.Policy = .init(cooldown: 600)
    ) -> AlertDispatcher {
        AlertDispatcher(sinks: [sink], policy: policy, host: "mini")
    }

    private func alert(_ source: String, _ message: String = "boom") -> FleetStatusAlert {
        FleetStatusAlert(source: source, message: message)
    }

    func testKindFilterDeliversOnlyTheSelectedKinds() async {
        let sink = FakeAlertSink()
        let dispatcher = make(sink, policy: .init(kinds: [.disk, .queue], cooldown: 600))
        await dispatcher.observe(
            [alert("disk"), alert("queue:github"), alert("credentials"), alert("orphans"), alert("healing")], now: t0)
        XCTAssertEqual(sink.sent.map(\.source).sorted(), ["disk", "queue:github"])
    }

    func testEachWebhookKeepsItsOwnCooldownAndResolveRecord() async {
        let loud = FakeAlertSink()
        let quiet = FakeAlertSink()
        let a = make(loud, policy: .init(cooldown: 600))
        let b = make(quiet, policy: .init(kinds: [.credentials], cooldown: 600, notifyOnResolve: false))
        for dispatcher in [a, b] { await dispatcher.observe([alert("disk"), alert("credentials")], now: t0) }
        for dispatcher in [a, b] { await dispatcher.observe([], now: t0.addingTimeInterval(30)) }
        XCTAssertEqual(loud.sent.map(\.state), [.firing, .firing, .resolved, .resolved])
        XCTAssertEqual(quiet.sent.map(\.state), [.firing], "filtered and no resolve")
    }

    func testAFailingWebhookDoesNotHoldBackAnother() async {
        let down = FakeAlertSink()
        down.failing = true
        let up = FakeAlertSink()
        await make(down).observe([alert("disk")], now: t0)
        await make(up).observe([alert("disk")], now: t0)
        XCTAssertEqual(up.sent.count, 1)
    }

    func testNewAlertFiresOnce() async {
        let sink = FakeAlertSink()
        let dispatcher = make(sink)
        await dispatcher.observe([alert("disk")], now: t0)
        await dispatcher.observe([alert("disk")], now: t0.addingTimeInterval(30))
        XCTAssertEqual(sink.sent.map(\.state), [.firing])
        XCTAssertEqual(sink.sent.first?.source, "disk")
        XCTAssertEqual(sink.sent.first?.severity, .critical)
        XCTAssertEqual(sink.sent.first?.host, "mini")
    }

    func testRefiresAfterCooldown() async {
        let sink = FakeAlertSink()
        let dispatcher = make(sink)
        await dispatcher.observe([alert("disk")], now: t0)
        await dispatcher.observe([alert("disk")], now: t0.addingTimeInterval(601))
        XCTAssertEqual(sink.sent.map(\.state), [.firing, .firing])
    }

    func testResolvedWhenCleared() async {
        let sink = FakeAlertSink()
        let dispatcher = make(sink)
        await dispatcher.observe([alert("disk")], now: t0)
        await dispatcher.observe([], now: t0.addingTimeInterval(20))
        await dispatcher.observe([], now: t0.addingTimeInterval(40))
        XCTAssertEqual(sink.sent.map(\.state), [.firing, .resolved])
    }

    func testNoResolvedWhenDisabled() async {
        let sink = FakeAlertSink()
        let dispatcher = make(sink, policy: .init(cooldown: 600, notifyOnResolve: false))
        await dispatcher.observe([alert("disk")], now: t0)
        await dispatcher.observe([], now: t0.addingTimeInterval(20))
        XCTAssertEqual(sink.sent.map(\.state), [.firing])
    }

    func testMinSeverityFiltersWarnings() async {
        let sink = FakeAlertSink()
        let dispatcher = make(sink, policy: .init(minSeverity: .critical, cooldown: 600))
        await dispatcher.observe([alert("spawn-backoff"), alert("credentials")], now: t0)
        XCTAssertEqual(sink.sent.map(\.source), ["credentials"])
    }

    func testFailingSinkDoesNotThrowOrStopLaterEvents() async {
        let sink = FakeAlertSink()
        sink.failing = true
        let dispatcher = make(sink)
        await dispatcher.observe([alert("disk"), alert("credentials")], now: t0)
        XCTAssertEqual(sink.sent.count, 2)
    }

    func testFiringThatFailedIsRetriedAfterTheRetryIntervalNotTheCooldown() async {
        let sink = FakeAlertSink()
        sink.failing = true
        let dispatcher = make(sink, policy: .init(cooldown: 3_600, retryInterval: 60))
        await dispatcher.observe([alert("disk")], now: t0)
        await dispatcher.observe([alert("disk")], now: t0.addingTimeInterval(30))
        XCTAssertEqual(sink.sent.count, 1, "too early to retry")
        sink.failing = false
        await dispatcher.observe([alert("disk")], now: t0.addingTimeInterval(61))
        XCTAssertEqual(sink.sent.map(\.state), [.firing, .firing])
        await dispatcher.observe([alert("disk")], now: t0.addingTimeInterval(120))
        XCTAssertEqual(sink.sent.count, 2, "delivered, so the cooldown applies again")
    }

    func testResolutionThatFailedIsKeptUntilItIsDelivered() async {
        let sink = FakeAlertSink()
        let dispatcher = make(sink, policy: .init(cooldown: 3_600, retryInterval: 60))
        await dispatcher.observe([alert("disk")], now: t0)
        sink.failing = true
        await dispatcher.observe([], now: t0.addingTimeInterval(20))
        XCTAssertEqual(sink.sent.map(\.state), [.firing, .resolved])
        await dispatcher.observe([], now: t0.addingTimeInterval(40))
        XCTAssertEqual(sink.sent.count, 2, "too early to retry")
        sink.failing = false
        await dispatcher.observe([], now: t0.addingTimeInterval(81))
        XCTAssertEqual(sink.sent.map(\.state), [.firing, .resolved, .resolved])
        await dispatcher.observe([], now: t0.addingTimeInterval(200))
        XCTAssertEqual(sink.sent.count, 3, "delivered once, not again")
    }

    func testNoResolutionForAFiringThatNeverArrived() async {
        let sink = FakeAlertSink()
        sink.failing = true
        let dispatcher = make(sink)
        await dispatcher.observe([alert("disk")], now: t0)
        sink.failing = false
        await dispatcher.observe([], now: t0.addingTimeInterval(20))
        XCTAssertEqual(sink.sent.map(\.state), [.firing])
    }

    func testPendingResolutionIsDroppedWhenTheProblemReturns() async {
        let sink = FakeAlertSink()
        let dispatcher = make(sink, policy: .init(cooldown: 3_600, retryInterval: 60))
        await dispatcher.observe([alert("disk")], now: t0)
        sink.failing = true
        await dispatcher.observe([], now: t0.addingTimeInterval(20))
        sink.failing = false
        await dispatcher.observe([alert("disk")], now: t0.addingTimeInterval(30))
        await dispatcher.observe([alert("disk")], now: t0.addingTimeInterval(200))
        XCTAssertEqual(sink.sent.map(\.state), [.firing, .resolved, .firing])
    }

    func testMessageIsRedacted() {
        LogRedactor.registerSecret("s3cr3t-token-value")
        let event = AlertEvent(
            source: "x", severity: .critical, state: .firing, message: "failed with s3cr3t-token-value", host: "h",
            timestamp: t0)
        XCTAssertFalse(event.message.contains("s3cr3t-token-value"))
    }
}
