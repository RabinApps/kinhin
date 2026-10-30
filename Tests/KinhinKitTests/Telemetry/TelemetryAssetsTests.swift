import Foundation
import XCTest

@testable import KinhinKit

/// The shipped dashboard and alert rules name only metrics kinhin really emits.
final class TelemetryAssetsTests: XCTestCase {
    private var docs: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/telemetry")
    }

    /// Every Prometheus-form name kinhin can emit: dots become underscores, counters may end `_total`, histograms
    /// `_bucket`, `_count` or `_sum`.
    private var known: Set<String> {
        func prom(_ name: String) -> String { name.replacingOccurrences(of: ".", with: "_") }
        var names = Set<String>()
        for counter in Metric.Counter.allCases {
            names.insert(prom(counter.rawValue))
            names.insert(prom(counter.rawValue) + "_total")
        }
        for histogram in Metric.Histogram.allCases {
            for suffix in ["", "_bucket", "_count", "_sum"] { names.insert(prom(histogram.rawValue) + suffix) }
        }
        for gauge in Metric.Gauge.allCases { names.insert(prom(gauge.rawValue)) }
        return names
    }

    private func metricNames(in text: String) -> Set<String> {
        let pattern = #"\b(?:kinhin|cicd|process)_[a-z0-9_]+"#
        let regex = try! NSRegularExpression(pattern: pattern)  // a literal pattern
        let range = NSRange(text.startIndex..., in: text)
        return Set(
            regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
    }

    /// Attribute names share the prefixes; they are not metrics.
    private let attributes: Set<String> = [
        "kinhin_pool", "kinhin_image", "kinhin_forge", "kinhin_account", "kinhin_runner_labels", "kinhin_runner_phase",
        "cicd_worker_state", "cicd_pipeline_result", "cicd_pipeline_name", "cicd_system_component",
        "kinhin_healing_result", "kinhin_runner_name",
    ]

    func testDashboardUsesOnlyEmittedMetrics() throws {
        let text = try String(contentsOf: docs.appendingPathComponent("kinhin-dashboard.json"), encoding: .utf8)
        _ = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let unknown = metricNames(in: text).subtracting(known).subtracting(attributes)
        XCTAssertTrue(unknown.isEmpty, "the dashboard names metrics kinhin does not emit: \(unknown.sorted())")
    }

    func testAlertsUseOnlyEmittedMetrics() throws {
        let text = try String(contentsOf: docs.appendingPathComponent("kinhin-alerts.yml"), encoding: .utf8)
        // The alert names themselves start with `Kinhin` (capital), which the pattern does not match.
        let unknown = metricNames(in: text).subtracting(known).subtracting(attributes)
        XCTAssertTrue(unknown.isEmpty, "the alert rules name metrics kinhin does not emit: \(unknown.sorted())")
        XCTAssertFalse(metricNames(in: text).isEmpty)
    }
}
