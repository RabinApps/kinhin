import XCTest

@testable import KinhinKit
@testable import kinhin

final class TelemetryCommandTests: XCTestCase {
    private func status(enabled: Bool = true, failureAgo: TimeInterval? = nil) -> TelemetryStatus {
        var status = TelemetryStatus.disabled
        status.enabled = enabled
        status.signals = ["metrics", "traces"]
        status.otlpProtocol = "http/protobuf"
        status.endpoints = ["metrics": "http://127.0.0.1:4318/v1/metrics", "traces": "http://127.0.0.1:4318/v1/traces"]
        status.prometheus = "127.0.0.1:9469"
        status.startedAt = Date(timeIntervalSinceNow: -3_600)
        if let failureAgo {
            status.lastFailureAt = Date(timeIntervalSinceNow: -failureAgo)
            status.lastFailure = "connection refused"
            status.exportFailures = 3
        }
        return status
    }

    func testRenderShowsTargetsAndHealth() {
        let text = TelemetryCommand.render(.init(daemon: true, status: status(), message: nil))
        XCTAssertTrue(text.contains("telemetry: on, http/protobuf, signals metrics, traces"), text)
        XCTAssertTrue(text.contains("metrics -> http://127.0.0.1:4318/v1/metrics"), text)
        XCTAssertTrue(text.contains("http://127.0.0.1:9469/metrics"), text)
        XCTAssertTrue(text.contains("no export problems reported"), text)
    }

    func testRenderReportsAFailure() {
        let text = TelemetryCommand.render(.init(daemon: true, status: status(failureAgo: 30), message: nil))
        XCTAssertTrue(text.contains("export problem"), text)
        XCTAssertTrue(text.contains("connection refused"), text)
        XCTAssertTrue(text.contains("3 so far"), text)
    }

    func testOffIsHealthyAndFailuresAreNot() {
        XCTAssertTrue(TelemetryCommand.healthy(.init(daemon: true, status: status(enabled: false), message: nil)))
        XCTAssertTrue(TelemetryCommand.healthy(.init(daemon: true, status: status(), message: nil)))
        XCTAssertFalse(TelemetryCommand.healthy(.init(daemon: true, status: status(failureAgo: 30), message: nil)))
        XCTAssertTrue(
            TelemetryCommand.healthy(.init(daemon: true, status: status(failureAgo: 7_200), message: nil)),
            "an old failure no longer counts")
    }

    func testNoDaemonIsOnlyAProblemWhenTheConfigEnablesTelemetry() async throws {
        var config = KinhinConfig.default
        let off = try await TelemetryCommand.document(config: config)
        // A real daemon may be running on the developer's Mac; the config-only path is what is under test.
        if !off.daemon {
            XCTAssertTrue(TelemetryCommand.healthy(off))
            config.telemetry.enabled = true
            let on = try await TelemetryCommand.document(config: config)
            XCTAssertFalse(TelemetryCommand.healthy(on))
            XCTAssertTrue(TelemetryCommand.render(on).contains("no daemon is running"))
        }
    }

    func testRPCMethodIsAReadAndKnownToTheWire() {
        XCTAssertFalse(RPCMethod.telemetryStatus.mutatesFleet)
        XCTAssertEqual(RPCMethod.telemetryStatus.rawValue, "telemetry_status")
    }
}
