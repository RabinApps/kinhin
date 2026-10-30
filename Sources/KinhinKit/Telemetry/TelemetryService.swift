import Foundation
import Synchronization

/// Owns the process's telemetry pipeline: starts the exporters once, hands the engine a stable
/// `Telemetry` handle, applies config reloads without duplicating providers or leaving a listener
/// bound, and flushes on an orderly exit.
///
/// One owner per process, in the process that hosts a production engine: the daemon, foreground
/// `kinhin start`, and an app that runs its own in-process engine. An app attached to the daemon
/// never starts one (the daemon already exports for that fleet).
public actor TelemetryService {
    /// What `apply` did.
    public enum Outcome: Sendable, Equatable {
        /// Telemetry is off: nothing was started (or what ran was stopped).
        case disabled
        /// The settings match what is running; nothing changed.
        case unchanged
        /// A pipeline is running with the new settings.
        case started
        /// The pipeline could not start; telemetry stays off.
        case failed(String)
    }

    typealias BackendFactory = @Sendable (TelemetrySettings) throws -> any TelemetryBackend

    /// The process-wide owner production hosts use.
    public static let shared = TelemetryService()

    /// Stable for the process: engines hold it across reloads.
    public nonisolated let telemetry: Telemetry

    private let environment: @Sendable () -> [String: String]
    private let host: TelemetryHostInfo
    private let makeBackend: BackendFactory
    private var running: TelemetrySettings?
    private var backendPort = 0

    public init() {
        self.init(
            environment: { ProcessInfo.processInfo.environment }, host: .current,
            makeBackend: { try OTelBackend(settings: $0) }, handle: Telemetry())
    }

    init(
        environment: @escaping @Sendable () -> [String: String], host: TelemetryHostInfo = .current,
        makeBackend: @escaping BackendFactory, handle: Telemetry = Telemetry()
    ) {
        self.environment = environment
        self.host = host
        self.makeBackend = makeBackend
        self.telemetry = handle
    }

    /// The settings the running pipeline was started with (nil while off).
    var currentSettings: TelemetrySettings? { running }

    /// Starts, restarts or stops the pipeline to match `config` (the `telemetry:` section plus `OTEL_*`).
    /// Idempotent: unchanged settings leave the running exporters alone. Always applies the local
    /// log format, which does not depend on `enabled`.
    @discardableResult
    public func apply(_ config: KinhinConfig.TelemetryConfig) async -> Outcome {
        Log.format = config.logFormat
        let settings = TelemetryResolver.resolve(config, environment: environment(), host: host)
        if settings == (running ?? .disabled), running != nil || !settings.enabled {
            return settings.enabled ? .unchanged : .disabled
        }
        for warning in settings.warnings { Log.warn("telemetry", warning) }

        // Stop what runs first: a new pipeline may want the same scrape port.
        await stop()
        guard settings.enabled else {
            Log.info("telemetry", "disabled")
            return .disabled
        }
        do {
            let backend = try makeBackend(settings)
            _ = telemetry.swap(to: backend, enabled: true)
            running = settings
            if settings.signals.contains(.logs) { Log.telemetry = telemetry }
            if let prometheus = settings.prometheus, !prometheus.isLoopback {
                Log.warn(
                    "telemetry",
                    "the Prometheus endpoint listens on \(prometheus.host):\(prometheus.port), which is not loopback: anyone who can reach it can read fleet metrics"
                )
            }
            Log.info("telemetry", settings.description)
            return .started
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error("telemetry", "could not start: \(message); telemetry stays off")
            return .failed(message)
        }
    }

    /// Flushes pending exports and stops every exporter and listener. The handle stays valid (it
    /// records nothing afterwards), so engines still running do not need to know.
    public func shutdown() async {
        await stop()
    }

    private func stop() async {
        guard running != nil else { return }
        Log.telemetry = nil
        let old = telemetry.swap(to: NoopBackend(), enabled: false)
        running = nil
        await old.shutdown()
    }
}
