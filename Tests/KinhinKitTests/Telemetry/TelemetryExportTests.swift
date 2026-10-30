import Foundation
import XCTest

@testable import KinhinKit

/// The SDK-backed pipeline end to end, with no collector: the Prometheus scrape endpoint on an
/// ephemeral loopback port serves what the instruments recorded.
final class TelemetryExportTests: XCTestCase {
    private func settings(prometheusPort: Int?) -> TelemetrySettings {
        var settings = TelemetryResolver.resolve(
            KinhinConfig.TelemetryConfig(enabled: true, signals: [.metrics]),
            environment: [:], host: TelemetryHostInfo(hostName: "h", architecture: "arm64", osVersion: "26.0.0"))
        settings.endpoints = [:]
        settings.prometheus = prometheusPort.map { TelemetryListenAddress(host: "127.0.0.1", port: $0) }
        return settings
    }

    private func get(_ path: String, port: Int, method: String = "GET") async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    func testMetricsEndpointExposesEmittedInstruments() async throws {
        let backend = try OTelBackend(settings: settings(prometheusPort: 0))
        defer { Task { await backend.shutdown() } }
        let port = backend.prometheusPort
        XCTAssertGreaterThan(port, 0)

        backend.add(counter: Metric.Counter.jobsPickedUp.rawValue, value: 3, attributes: [Metric.Attr.pool: "tart"])
        backend.record(
            histogram: Metric.Histogram.phaseDuration.rawValue, seconds: 2.5, attributes: [Metric.Attr.phase: "clone"])
        backend.publish(
            gauge: Metric.Gauge.workers.rawValue,
            series: [GaugeSeries(attributes: [Metric.Attr.pool: "tart", Metric.Attr.state: "ready"], value: 2)])

        let (status, body) = try await get("/metrics", port: port)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("kinhin_jobs_picked_up"), body)
        XCTAssertTrue(body.contains("kinhin_runner_provision_duration"), body)
        XCTAssertTrue(body.contains("cicd_worker_count"), body)
        XCTAssertTrue(body.contains("cicd_worker_state=\"ready\""), body)

        // A vanished series stops reporting: gauges are snapshots, not accumulations.
        backend.publish(gauge: Metric.Gauge.workers.rawValue, series: [])
        let (_, after) = try await get("/metrics", port: port)
        XCTAssertFalse(after.contains("cicd_worker_state=\"ready\""), after)
    }

    func testOnlyMetricsIsServed() async throws {
        let backend = try OTelBackend(settings: settings(prometheusPort: 0))
        defer { Task { await backend.shutdown() } }
        let port = backend.prometheusPort
        let (notFound, _) = try await get("/other", port: port)
        XCTAssertEqual(notFound, 404)
        let (post, _) = try await get("/metrics", port: port, method: "POST")
        XCTAssertEqual(post, 405)
    }

    func testShutdownReleasesThePort() async throws {
        let backend = try OTelBackend(settings: settings(prometheusPort: 0))
        let port = backend.prometheusPort
        await backend.shutdown()
        // Bound again at once, as a config reload does.
        let again = try OTelBackend(settings: settings(prometheusPort: port))
        XCTAssertEqual(again.prometheusPort, port)
        await again.shutdown()
    }

    func testNoPrometheusSettingOpensNoListener() async throws {
        let backend = try OTelBackend(settings: settings(prometheusPort: nil))
        XCTAssertEqual(backend.prometheusPort, 0)
        await backend.shutdown()
    }

    func testListenerRejectsABoundPort() async throws {
        let first = try OTelBackend(settings: settings(prometheusPort: 0))
        defer { Task { await first.shutdown() } }
        XCTAssertThrowsError(try OTelBackend(settings: settings(prometheusPort: first.prometheusPort)))
    }

    func testResponseRouting() {
        let ok = PrometheusListener.response(forRequest: "GET /metrics?x=1 HTTP/1.1\r\nHost: a\r\n\r\n") { "body" }
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(ok.hasSuffix("body"))
        XCTAssertTrue(PrometheusListener.response(forRequest: "GET / HTTP/1.1\r\n\r\n") { "" }.contains("404"))
        XCTAssertTrue(PrometheusListener.response(forRequest: "garbage") { "" }.contains("400"))
    }
}
