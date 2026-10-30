import Foundation
import Synchronization

// The SDK-independent telemetry surface the engine records through. The OpenTelemetry
// SDK sits behind `TelemetryBackend` (see `OTelBackend`); everything else in kinhin sees
// only these types, so the engine builds and behaves the same with telemetry off.

// MARK: - Values

/// A span or log attribute value.
public enum TelemetryValue: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral
{
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
}

public typealias TelemetryAttributes = [String: TelemetryValue]

/// Metric attributes are strings drawn from small closed sets (pool, image, forge, phase, result, error type…).
/// Identifiers (VM, job, run, trace) never go here: they belong on spans and log records.
typealias MetricAttributes = [String: String]

public struct TelemetrySpanContext: Sendable, Equatable {
    public let traceID: String
    public let spanID: String
}

public protocol TelemetrySpan: Sendable {
    var context: TelemetrySpanContext? { get }
    func setAttributes(_ attributes: TelemetryAttributes)
    /// A child span; `start` backdates it when its interval came from a provider timestamp.
    func startChild(_ name: String, start: Date?, attributes: TelemetryAttributes) -> any TelemetrySpan
    /// Ends the span; a non-nil `error` marks it failed.
    func end(at: Date?, error: String?)
}

extension TelemetrySpan {
    public func startChild(_ name: String, attributes: TelemetryAttributes = [:]) -> any TelemetrySpan {
        startChild(name, start: nil, attributes: attributes)
    }

    public func end(error: String? = nil) { end(at: nil, error: error) }
}

struct NoopSpan: TelemetrySpan {
    var context: TelemetrySpanContext? { nil }
    func setAttributes(_ attributes: TelemetryAttributes) {}
    func startChild(_ name: String, start: Date?, attributes: TelemetryAttributes) -> any TelemetrySpan { self }
    func end(at: Date?, error: String?) {}
}

/// One structured log record headed for the OTLP log pipeline.
struct TelemetryLogRecord: Sendable, Equatable {
    var timestamp: Date
    var level: Log.Level
    var component: String
    var message: String
    var attributes: [String: String]
    var trace: TelemetrySpanContext?
}

/// One labelled value of a gauge snapshot.
struct GaugeSeries: Sendable, Equatable {
    var attributes: MetricAttributes
    var value: Double
}

// MARK: - Backend

/// The export pipeline behind a `Telemetry` handle.
protocol TelemetryBackend: Sendable {
    func add(counter name: String, value: Int, attributes: MetricAttributes)
    func record(histogram name: String, seconds: Double, attributes: MetricAttributes)
    /// Replaces every series of a snapshot gauge, so a pool or state that vanished stops reporting.
    func publish(gauge name: String, series: [GaugeSeries])
    func startSpan(_ name: String, start: Date?, attributes: TelemetryAttributes) -> any TelemetrySpan
    func emit(log: TelemetryLogRecord)
    /// Flushes pending exports and releases exporters and listeners.
    func shutdown() async
}

struct NoopBackend: TelemetryBackend {
    func add(counter name: String, value: Int, attributes: MetricAttributes) {}
    func record(histogram name: String, seconds: Double, attributes: MetricAttributes) {}
    func publish(gauge name: String, series: [GaugeSeries]) {}
    func startSpan(_ name: String, start: Date?, attributes: TelemetryAttributes) -> any TelemetrySpan { NoopSpan() }
    func emit(log: TelemetryLogRecord) {}
    func shutdown() async {}
}

// MARK: - Handle

/// The handle the engine records telemetry through. It is stable for the process: the
/// owner (`TelemetryService`) swaps the backend underneath on a config reload, so engines
/// built before or after a reload keep one handle and never see a half-started pipeline.
public final class Telemetry: Sendable {
    private let backendBox: Mutex<any TelemetryBackend>
    private let enabledBox: Mutex<Bool>

    /// A handle that records nothing (the default for every engine).
    public static let noop = Telemetry()

    public convenience init() {
        self.init(backend: NoopBackend(), enabled: false)
    }

    init(backend: any TelemetryBackend, enabled: Bool = true) {
        backendBox = Mutex(backend)
        enabledBox = Mutex(enabled)
    }

    /// False for the no-op: call sites skip building attributes.
    public var isEnabled: Bool { enabledBox.withLock { $0 } }

    var backend: any TelemetryBackend { backendBox.withLock { $0 } }

    /// Swaps in a new backend, returning the old one for the caller to shut down.
    func swap(to backend: any TelemetryBackend, enabled: Bool) -> any TelemetryBackend {
        enabledBox.withLock { $0 = enabled }
        return backendBox.withLock { current in
            defer { current = backend }
            return current
        }
    }

    // MARK: Primitives

    func add(_ counter: Metric.Counter, _ value: Int = 1, _ attributes: MetricAttributes = [:]) {
        guard isEnabled else { return }
        backend.add(counter: counter.rawValue, value: value, attributes: attributes)
    }

    func record(_ histogram: Metric.Histogram, seconds: Double, _ attributes: MetricAttributes = [:]) {
        guard isEnabled, seconds >= 0, seconds.isFinite else { return }
        backend.record(histogram: histogram.rawValue, seconds: seconds, attributes: attributes)
    }

    func publish(_ gauge: Metric.Gauge, _ series: [GaugeSeries]) {
        guard isEnabled else { return }
        backend.publish(gauge: gauge.rawValue, series: series)
    }

    public func startSpan(
        _ name: String, start: Date? = nil, attributes: TelemetryAttributes = [:]
    ) -> any TelemetrySpan {
        guard isEnabled else { return NoopSpan() }
        return backend.startSpan(name, start: start, attributes: attributes)
    }

    func emit(log record: TelemetryLogRecord) {
        guard isEnabled else { return }
        backend.emit(log: record)
    }
}

// MARK: - Metric catalog

/// Every instrument kinhin emits. Names follow OpenTelemetry style (`kinhin.` prefix, dotted);
/// the Prometheus exporter renders dots as underscores.
enum Metric {
    enum Counter: String, CaseIterable {
        case jobsPickedUp = "kinhin.jobs.picked_up"
        case jobsCompleted = "kinhin.jobs.completed"
        case warmClaims = "kinhin.warm_pool.claims"
        case warmEvictions = "kinhin.warm_pool.evictions"
        case healingActions = "kinhin.healing.actions"
        case forgeRequests = "kinhin.forge.requests"
        case errors = "kinhin.errors"
    }

    enum Histogram: String, CaseIterable {
        case phaseDuration = "kinhin.vm.phase.duration"
        case queueWait = "kinhin.job.queue_wait.duration"
        case runDuration = "kinhin.job.run.duration"
    }

    enum Gauge: String, CaseIterable {
        case workers = "kinhin.workers"
        case queueDepth = "kinhin.queue.depth"
        case queueAgeMax = "kinhin.queue.age.max"
        case fleetDesired = "kinhin.fleet.desired"
        case fleetActive = "kinhin.fleet.active"
        case fleetCapacity = "kinhin.fleet.capacity"
        case fleetPaused = "kinhin.fleet.paused"
        case fleetRunning = "kinhin.fleet.running"
        case warmSize = "kinhin.warm_pool.size"
        case jobsActive = "kinhin.jobs.active"
        case runnerCPU = "kinhin.runner.cpu.utilization"
        case runnerMemoryUsage = "kinhin.runner.memory.usage"
        case runnerMemoryLimit = "kinhin.runner.memory.limit"
        case hostCPU = "kinhin.host.cpu.utilization"
        case hostMemoryUsage = "kinhin.host.memory.usage"
        case hostMemoryLimit = "kinhin.host.memory.limit"
        case hostDiskFree = "kinhin.host.disk.free"
        case processCPU = "kinhin.process.cpu.utilization"
        case processMemory = "kinhin.process.memory.usage"
        case rateLimitRemaining = "kinhin.forge.rate_limit.remaining"
        case rateLimitLimit = "kinhin.forge.rate_limit.limit"
        case healingPending = "kinhin.healing.awaiting_approval"
    }

    /// The VM lifecycle phases timed directly by the engine.
    enum Phase: String {
        case provision
        case bootReady = "boot_ready"
        case registration
        case run
        case teardown
    }
}
