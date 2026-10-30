import Foundation
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class TelemetryStatusTests: XCTestCase {
    override func tearDown() {
        TelemetryHealth.shared.reset()
        TelemetryHealth.install(false)
        super.tearDown()
    }

    func testRepeatedProblemsAreLoggedOncePerMinuteButAllCounted() {
        let health = TelemetryHealth()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(health.record("connection refused", now: t0))
        XCTAssertFalse(health.record("connection refused", now: t0 + 10))
        XCTAssertTrue(health.record("a different problem", now: t0 + 11))
        XCTAssertTrue(health.record("connection refused", now: t0 + 61), "logged again after a minute")
        var status = TelemetryStatus.disabled
        health.apply(to: &status)
        XCTAssertEqual(status.exportFailures, 4)
        XCTAssertEqual(status.lastFailure, "connection refused")
        XCTAssertEqual(status.lastFailureAt, t0 + 61)
    }

    func testProblemTextIsRedactedAndShortened() {
        let cleaned = TelemetryHealth.clean(
            "401 from collector: token ghp_abcdefghijklmnopqrstuvwxyz0123456789\n" + String(repeating: "x", count: 400))
        XCTAssertFalse(cleaned.contains("ghp_abc"))
        XCTAssertFalse(cleaned.contains("\n"))
        XCTAssertLessThanOrEqual(cleaned.count, TelemetryHealth.maxMessage + 1)
    }

    func testMemoryOfDistinctProblemsIsBounded() {
        let health = TelemetryHealth()
        for index in 0..<500 { health.record("problem number \(index) \(String(repeating: "p", count: 90))") }
        var status = TelemetryStatus.disabled
        health.apply(to: &status)
        XCTAssertEqual(status.exportFailures, 500)
    }

    func testRecentFailureWindow() {
        var status = TelemetryStatus.disabled
        let now = Date()
        XCTAssertFalse(status.hasRecentFailure(now: now))
        status.lastFailureAt = now - 60
        XCTAssertTrue(status.hasRecentFailure(now: now))
        status.lastFailureAt = now - 3_600
        XCTAssertFalse(status.hasRecentFailure(now: now))
    }

    func testEndpointsInStatusCarryNoCredentialsOrQuery() {
        let url = URL(string: "https://user:s3cret@collector.example.com:4318/v1/metrics?token=abc#frag")!
        let shown = TelemetryStatus.redacted(url)
        XCTAssertEqual(shown, "https://collector.example.com:4318/v1/metrics")
    }

    func testServiceStatusMirrorsTheRunningPipeline() async {
        let recorder = RecordingTelemetryBackend()
        let service = TelemetryService(environment: { [:] }, makeBackend: { _ in recorder })
        let off = await service.status()
        XCTAssertFalse(off.enabled)
        var config = KinhinConfig.TelemetryConfig(enabled: true)
        config.endpoint = "http://user:pw@127.0.0.1:4318"
        config.signals = [.metrics, .logs]
        config.jobAttributes = [.repository]
        await service.apply(config)
        let on = await service.status()
        XCTAssertTrue(on.enabled)
        XCTAssertEqual(on.signals, ["logs", "metrics"])
        XCTAssertEqual(on.otlpProtocol, "http/protobuf")
        XCTAssertEqual(on.endpoints["metrics"], "http://127.0.0.1:4318/v1/metrics")
        XCTAssertEqual(on.jobAttributes, ["repository"])
        XCTAssertNotNil(on.startedAt)
        XCTAssertFalse("\(on)".contains("pw"), "no credential in the status")
        await service.shutdown()
        let after = await service.status()
        XCTAssertFalse(after.enabled)
    }

    func testFeedbackReachesHealthWhileAPipelineRuns() async {
        let service = TelemetryService(environment: { [:] }, makeBackend: { _ in RecordingTelemetryBackend() })
        await service.apply(KinhinConfig.TelemetryConfig(enabled: true))
        TelemetryHealth.shared.handle("export failed: connection refused")
        let status = await service.status()
        XCTAssertEqual(status.exportFailures, 1)
        XCTAssertEqual(status.lastFailure, "export failed: connection refused")
        // The record is not forwarded to the OTLP log pipeline.
        let recorder = RecordingTelemetryBackend()
        Log.telemetry = Telemetry(backend: recorder)
        defer { Log.telemetry = nil }
        TelemetryHealth.shared.handle("another failure")
        XCTAssertFalse(recorder.logs.contains { $0.component == TelemetryHealth.logComponent })
        await service.shutdown()
    }

    func testStatusSurvivesJSONRoundTrip() throws {
        var status = TelemetryStatus.disabled
        status.enabled = true
        status.lastFailure = "x"
        status.lastFailureAt = Date(timeIntervalSince1970: 5)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(TelemetryStatus.self, from: encoder.encode(status)), status)
    }
}
