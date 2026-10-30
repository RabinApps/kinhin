import Foundation
import OpenTelemetrySdk

/// Renders collected metrics in the Prometheus text format (0.0.4).
///
/// The SDK's own writer is not used for the scrape: it writes histogram buckets as per-bucket counts under the base
/// name (Prometheus wants cumulative `le` counts as `_bucket`), and one series per single label rather than per label
/// set, so `histogram_quantile` over its output is wrong. Counters, gauges and histograms are written here instead;
/// other instrument types are not created by kinhin and are skipped.
enum PrometheusText {
    static func render(_ metrics: [MetricData]) -> String {
        var output = ""
        for metric in metrics {
            let name = safeName(metric.name)
            let type: String
            switch metric.type {
            case .DoubleSum, .LongSum: type = "counter"
            case .DoubleGauge, .LongGauge: type = "gauge"
            case .Histogram: type = "histogram"
            default: continue
            }
            if !metric.description.isEmpty {
                output += "# HELP \(name) \(escape(metric.description, quotes: false))\n"
            }
            output += "# TYPE \(name) \(type)\n"
            for point in metric.data.points {
                let labels = point.attributes.mapValues { $0.description }
                switch metric.type {
                case .DoubleSum, .DoubleGauge:
                    guard let point = point as? DoublePointData else { continue }
                    output += line(name, labels, point.value)
                case .LongSum, .LongGauge:
                    guard let point = point as? LongPointData else { continue }
                    output += line(name, labels, Double(point.value))
                default:
                    guard let point = point as? HistogramPointData else { continue }
                    output += histogram(name, labels, point)
                }
            }
        }
        return output
    }

    /// `_bucket` series with cumulative counts (the last, `+Inf`, equals `_count`), then `_sum` and `_count`.
    private static func histogram(_ name: String, _ labels: [String: String], _ point: HistogramPointData) -> String {
        var output = ""
        var cumulative = 0.0
        for (index, boundary) in point.boundaries.enumerated() {
            cumulative += Double(index < point.counts.count ? point.counts[index] : 0)
            output += line("\(name)_bucket", labels.merging(["le": format(boundary)]) { $1 }, cumulative)
        }
        // A well-formed point has one more count than boundaries (the overflow bucket); the total is `count`.
        output += line("\(name)_bucket", labels.merging(["le": "+Inf"]) { $1 }, Double(point.count))
        output += line("\(name)_sum", labels, point.sum)
        output += line("\(name)_count", labels, Double(point.count))
        return output
    }

    private static func line(_ name: String, _ labels: [String: String], _ value: Double) -> String {
        var text = name
        if !labels.isEmpty {
            // `le` last, as Prometheus clients write it; the rest sorted so a scrape is stable.
            let ordered = labels.keys.sorted { ($0 == "le" ? "\u{10FFFF}" : $0) < ($1 == "le" ? "\u{10FFFF}" : $1) }
            text +=
                "{"
                + ordered.map { "\(safeLabel($0))=\"\(escape(labels[$0] ?? "", quotes: true))\"" }.joined(
                    separator: ",") + "}"
        }
        return "\(text) \(format(value))\n"
    }

    /// Whole numbers without a fraction; `+Inf`, `-Inf` and `NaN` as Prometheus spells them.
    static func format(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Inf" : "+Inf" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    private static let nameStart = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_:")
    private static let nameRest = nameStart.union(CharacterSet(charactersIn: "0123456789"))

    private static func safeName(_ name: String) -> String {
        sanitized(name, start: nameStart, rest: nameRest)
    }

    private static func safeLabel(_ name: String) -> String {
        sanitized(
            name, start: nameStart.subtracting(CharacterSet(charactersIn: ":")),
            rest: nameRest.subtracting(CharacterSet(charactersIn: ":")))
    }

    private static func sanitized(_ name: String, start: CharacterSet, rest: CharacterSet) -> String {
        var scalars = name.unicodeScalars.map { rest.contains($0) ? Character($0) : "_" }
        if let first = name.unicodeScalars.first, !start.contains(first) { scalars.insert("_", at: 0) }
        return String(scalars)
    }

    private static func escape(_ text: String, quotes: Bool) -> String {
        var result = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
        if quotes { result = result.replacingOccurrences(of: "\"", with: "\\\"") }
        return result
    }
}
