import Foundation
import OpenTelemetryApi
import Synchronization

/// What `kinhin telemetry status` reports: whether the pipeline runs, where it sends, and whether exports are
/// failing. Never carries header values, URL credentials or query strings.
public struct TelemetryStatus: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var signals: [String]
    public var otlpProtocol: String?
    /// Collector URL per signal, with any credentials and query removed.
    public var endpoints: [String: String]
    /// The local scrape address actually bound (`127.0.0.1:9464`), when there is one.
    public var prometheus: String?
    public var jobAttributes: [String]
    public var startedAt: Date?
    public var exportFailures: Int
    public var lastFailureAt: Date?
    /// The most recent export problem, redacted and shortened.
    public var lastFailure: String?

    public static let disabled = TelemetryStatus(
        enabled: false, signals: [], otlpProtocol: nil, endpoints: [:], prometheus: nil, jobAttributes: [],
        startedAt: nil, exportFailures: 0, lastFailureAt: nil, lastFailure: nil)

    /// True when exports are failing right now: a failure and no success since is not tracked (the SDK reports only
    /// failures), so "recent" means within the last five minutes.
    public func hasRecentFailure(now: Date = Date()) -> Bool {
        guard let lastFailureAt else { return false }
        return now.timeIntervalSince(lastFailureAt) < 300
    }
}

/// Export problems the SDK reports through its feedback handler (it never throws them): a wrong endpoint, a refused
/// connection, a rejected batch. They would otherwise be silent. Each distinct problem is logged at most once a
/// minute, counted in `kinhin.telemetry.export.failures`, and remembered for `kinhin telemetry status`.
final class TelemetryHealth: Sendable {
    static let shared = TelemetryHealth()

    /// Log component of these lines. `Log` does not forward it to the OTLP log pipeline: a failing export must not
    /// queue the very record it complains about.
    static let logComponent = "telemetry-export"

    private struct State {
        var failures = 0
        var lastAt: Date?
        var lastMessage: String?
        var lastLogged: [String: Date] = [:]
    }
    private let state = Mutex(State())
    static let logInterval: TimeInterval = 60
    static let maxMessage = 200

    func reset() {
        state.withLock { $0 = State() }
    }

    /// Records one problem; returns whether it should be logged now (not seen in the last minute).
    @discardableResult
    func record(_ raw: String, now: Date = Date()) -> Bool {
        let message = Self.clean(raw)
        return state.withLock { state in
            state.failures += 1
            state.lastAt = now
            state.lastMessage = message
            let key = String(message.prefix(80))
            if let last = state.lastLogged[key], now.timeIntervalSince(last) < Self.logInterval { return false }
            state.lastLogged[key] = now
            // Bounded: a collector that answers with a different text each time cannot grow this without limit.
            if state.lastLogged.count > 64 { state.lastLogged = [key: now] }
            return true
        }
    }

    /// Fills the failure fields of `status`.
    func apply(to status: inout TelemetryStatus) {
        state.withLock { state in
            status.exportFailures = state.failures
            status.lastFailureAt = state.lastAt
            status.lastFailure = state.lastMessage
        }
    }

    /// Masks credentials and shortens one line of SDK output.
    static func clean(_ raw: String) -> String {
        let oneLine = LogRedactor.redact(raw).replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > maxMessage ? String(oneLine.prefix(maxMessage)) + "…" : oneLine
    }

    /// The SDK's feedback handler: log (rate-limited) and count.
    func handle(_ raw: String) {
        if record(raw) { Log.warn(Self.logComponent, "export problem: \(Self.clean(raw))") }
        TelemetryService.shared.telemetry.add(.exportFailures)
    }

    /// Routes the SDK's feedback to this tracker while a pipeline runs. The SDK has no way to unregister, so once
    /// stopped the handler goes quiet instead (`active` false).
    private static let active = Mutex(false)

    static func install(_ on: Bool) {
        active.withLock { $0 = on }
        guard on else { return }
        OpenTelemetry.registerFeedbackHandler { message in
            if active.withLock({ $0 }) { TelemetryHealth.shared.handle(message) }
        }
    }
}

extension TelemetryStatus {
    /// `url` without userinfo and query, which can carry credentials.
    static func redacted(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? ""
    }

    init(settings: TelemetrySettings, prometheusPort: Int, startedAt: Date) {
        self.init(
            enabled: settings.enabled, signals: settings.signals.map(\.rawValue).sorted(),
            otlpProtocol: settings.otlpProtocol.rawValue,
            endpoints: Dictionary(
                uniqueKeysWithValues: settings.endpoints.map { ($0.key.rawValue, Self.redacted($0.value)) }),
            prometheus: settings.prometheus.map { "\($0.host):\(prometheusPort > 0 ? prometheusPort : $0.port)" },
            jobAttributes: settings.jobAttributes.map(\.rawValue).sorted(), startedAt: startedAt,
            exportFailures: 0, lastFailureAt: nil, lastFailure: nil)
    }
}
