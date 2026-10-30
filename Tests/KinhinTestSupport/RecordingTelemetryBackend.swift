import Foundation
import Synchronization

@testable import KinhinKit

/// An in-memory `TelemetryBackend`: records every counter, histogram sample, gauge snapshot, span and
/// log record so tests assert on what the engine emitted without a collector.
final class RecordingTelemetryBackend: TelemetryBackend, @unchecked Sendable {
    struct CounterSample: Equatable {
        var name: String
        var value: Int
        var attributes: [String: String]
    }
    struct HistogramSample: Equatable {
        var name: String
        var seconds: Double
        var attributes: [String: String]
    }
    final class SpanRecord: @unchecked Sendable {
        let name: String
        let id: Int
        let parent: Int?
        var attributes: TelemetryAttributes
        var start: Date?
        var end: Date?
        var ended = false
        var error: String?
        init(name: String, id: Int, parent: Int?, attributes: TelemetryAttributes, start: Date?) {
            self.name = name
            self.id = id
            self.parent = parent
            self.attributes = attributes
            self.start = start
        }
    }

    private struct State {
        var counters: [CounterSample] = []
        var histograms: [HistogramSample] = []
        var gauges: [String: [GaugeSeries]] = [:]
        var spans: [SpanRecord] = []
        var logs: [TelemetryLogRecord] = []
        var shutdowns = 0
    }
    private let state = Mutex(State())

    var counters: [CounterSample] { state.withLock { $0.counters } }
    var histograms: [HistogramSample] { state.withLock { $0.histograms } }
    var spans: [SpanRecord] { state.withLock { $0.spans } }
    var logs: [TelemetryLogRecord] { state.withLock { $0.logs } }
    var shutdownCount: Int { state.withLock { $0.shutdowns } }
    func gauge(_ name: Metric.Gauge) -> [GaugeSeries]? { state.withLock { $0.gauges[name.rawValue] } }
    func counterTotal(_ name: Metric.Counter, where match: ([String: String]) -> Bool = { _ in true }) -> Int {
        counters.filter { $0.name == name.rawValue && match($0.attributes) }.reduce(0) { $0 + $1.value }
    }
    func histograms(_ name: Metric.Histogram) -> [HistogramSample] { histograms.filter { $0.name == name.rawValue } }
    func spans(named name: String) -> [SpanRecord] { spans.filter { $0.name == name } }

    func add(counter name: String, value: Int, attributes: MetricAttributes) {
        state.withLock { $0.counters.append(CounterSample(name: name, value: value, attributes: attributes)) }
    }
    func record(histogram name: String, seconds: Double, attributes: MetricAttributes) {
        state.withLock { $0.histograms.append(HistogramSample(name: name, seconds: seconds, attributes: attributes)) }
    }
    func publish(gauge name: String, series: [GaugeSeries]) {
        state.withLock { $0.gauges[name] = series }
    }
    func startSpan(_ name: String, start: Date?, attributes: TelemetryAttributes) -> any TelemetrySpan {
        makeSpan(name, parent: nil, start: start, attributes: attributes)
    }
    func emit(log: TelemetryLogRecord) { state.withLock { $0.logs.append(log) } }
    func shutdown() async { state.withLock { $0.shutdowns += 1 } }

    fileprivate func makeSpan(_ name: String, parent: Int?, start: Date?, attributes: TelemetryAttributes)
        -> RecordingSpan
    {
        let record = state.withLock { state -> SpanRecord in
            let record = SpanRecord(
                name: name, id: state.spans.count + 1, parent: parent, attributes: attributes, start: start)
            state.spans.append(record)
            return record
        }
        return RecordingSpan(record: record, backend: self)
    }
}

private final class RecordingSpan: TelemetrySpan, @unchecked Sendable {
    let record: RecordingTelemetryBackend.SpanRecord
    let backend: RecordingTelemetryBackend

    init(record: RecordingTelemetryBackend.SpanRecord, backend: RecordingTelemetryBackend) {
        self.record = record
        self.backend = backend
    }

    var context: TelemetrySpanContext? {
        TelemetrySpanContext(
            traceID: String(repeating: "a", count: 32), spanID: String(format: "%016x", record.id))
    }
    func setAttributes(_ attributes: TelemetryAttributes) {
        record.attributes.merge(attributes) { $1 }
    }
    func startChild(_ name: String, start: Date?, attributes: TelemetryAttributes) -> any TelemetrySpan {
        backend.makeSpan(name, parent: record.id, start: start, attributes: attributes)
    }
    func end(at: Date?, error: String?) {
        record.end = at
        record.ended = true
        record.error = error
    }
}
