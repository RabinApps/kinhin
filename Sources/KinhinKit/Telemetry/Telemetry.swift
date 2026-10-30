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
    /// Closes listening sockets at once, ahead of the slower `shutdown()`.
    func releaseListeners()
    /// Flushes pending exports and releases exporters and listeners.
    func shutdown() async
}

extension TelemetryBackend {
    func releaseListeners() {}
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
    private let jobAttributesBox = Mutex(Set<KinhinConfig.TelemetryConfig.JobAttribute>())
    private let logLevelBox = Mutex(Log.Level.info)

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

    /// The opt-in per-job dimensions in force (empty by default).
    var jobAttributes: Set<KinhinConfig.TelemetryConfig.JobAttribute> { jobAttributesBox.withLock { $0 } }

    func setJobAttributes(_ attributes: Set<KinhinConfig.TelemetryConfig.JobAttribute>) {
        jobAttributesBox.withLock { $0 = attributes }
    }

    /// The lowest severity sent to the OTLP log pipeline (`telemetry.log_level`); independent of `Log.minLevel`.
    var logLevel: Log.Level { logLevelBox.withLock { $0 } }

    func setLogLevel(_ level: Log.Level) {
        logLevelBox.withLock { $0 = level }
    }

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
        guard forwardsLogs(at: record.level) else { return }
        backend.emit(log: record)
    }

    /// Whether a record of `level` goes to the OTLP log pipeline (`telemetry.log_level`).
    func forwardsLogs(at level: Log.Level) -> Bool {
        isEnabled && level >= logLevel
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
        case forgeRequests = "kinhin.forge.api.requests"
        case errors = "cicd.system.errors"
        case exportFailures = "kinhin.telemetry.export.failures"
        case reconcileErrors = "kinhin.reconcile.errors"
        case spawnFailures = "kinhin.spawn.failures"
        case imageBakes = "kinhin.image.bakes"
        case cachePrunes = "kinhin.cache.prunes"
    }

    enum Histogram: String, CaseIterable {
        case phaseDuration = "kinhin.runner.provision.duration"
        case teardownDuration = "kinhin.runner.teardown.duration"
        case reconcileDuration = "kinhin.reconcile.duration"
        case queueWait = "kinhin.job.queue_wait.duration"
        case runDuration = "cicd.pipeline.run.duration"
        case imageBakeDuration = "kinhin.image.bake.duration"
    }

    enum Gauge: String, CaseIterable {
        case workers = "cicd.worker.count"
        case queueDepth = "kinhin.queue.depth"
        case queueDepthByPool = "kinhin.queue.pool.depth"
        case queueAge = "kinhin.queue.age"
        case fleetDesired = "kinhin.fleet.desired"
        case fleetActive = "kinhin.fleet.active"
        case poolCapacity = "kinhin.pool.capacity"
        case fleetPaused = "kinhin.fleet.paused"
        case fleetRunning = "kinhin.fleet.running"
        case warmSize = "kinhin.warm_pool.size"
        case jobsActive = "cicd.pipeline.run.active"
        case runnerCPU = "kinhin.runner.cpu.utilization"
        case runnerMemoryUsage = "kinhin.runner.memory.usage"
        case runnerMemoryLimit = "kinhin.runner.memory.limit"
        case hostCPU = "kinhin.host.cpu.utilization"
        case hostMemoryUsage = "kinhin.host.memory.usage"
        case hostMemoryLimit = "kinhin.host.memory.limit"
        case hostDiskFree = "kinhin.host.disk.free"
        case processCPU = "process.cpu.utilization"
        case processMemory = "process.memory.usage"
        case rateLimitRemaining = "kinhin.forge.rate_limit.remaining"
        case rateLimitLimit = "kinhin.forge.rate_limit.limit"
        case healingPending = "kinhin.healing.awaiting_approval"
        case buildInfo = "kinhin.build.info"
        case daemonUptime = "kinhin.daemon.uptime"
        case reconcileLastSuccess = "kinhin.reconcile.last_success"
        case spawnHeld = "kinhin.spawn.held"
        case cacheSize = "kinhin.cache.size"
        case runnerDiskUsage = "kinhin.runner.disk.usage"
    }

    /// Metric attribute keys. Names follow the OpenTelemetry CI/CD semantic conventions where one exists
    /// (`cicd.worker.*`, `cicd.pipeline.*`, `cicd.system.*`, `error.type`) and are `kinhin.`-prefixed otherwise.
    enum Attr {
        static let pool = "kinhin.pool"
        static let image = "kinhin.image"
        static let forge = "kinhin.forge"
        static let account = "kinhin.account"
        static let labels = "kinhin.runner.labels"
        static let state = "cicd.worker.state"
        static let phase = "kinhin.runner.phase"
        static let result = "cicd.pipeline.result"
        static let workflow = "cicd.pipeline.name"
        static let repository = "vcs.repository.name"
        static let errorType = "error.type"
        static let component = "cicd.system.component"
        static let statusClass = "http.response.status_class"
        static let healingResult = "kinhin.healing.result"
        static let version = "service.version"
        static let holdReason = "kinhin.spawn.hold_reason"
        /// The outcome of an image bake or cache prune: `success` or `failure`.
        static let outcome = "kinhin.result"
        /// Which host cache a size describes (`toolchain`).
        static let cache = "kinhin.cache"
    }

    /// The VM lifecycle phases timed directly by the engine.
    enum Phase: String {
        case provision
        case bootReady = "boot_ready"
        case registration
        case run
        case teardown

        /// The `kinhin.runner.phase` value on the provision histogram: what the phase does, not the span's name.
        var metricName: String {
            switch self {
            case .provision: return "clone"
            case .bootReady: return "boot"
            case .registration: return "register"
            case .run: return "run"
            case .teardown: return "teardown"
            }
        }
    }
}
