import Foundation

/// What a telemetry export pipeline runs with: the `telemetry:` config with the
/// standard `OTEL_*` environment applied on top. Resolved once per (re)start, so
/// the owner can tell whether a config reload actually changed anything.
///
/// Exporter headers (credentials) only ever come from `OTEL_EXPORTER_OTLP_HEADERS`;
/// they are held here for the exporters and never appear in `description`.
struct TelemetrySettings: Sendable, Equatable, CustomStringConvertible {
    typealias Signal = KinhinConfig.TelemetryConfig.Signal
    typealias OTLPProtocol = KinhinConfig.TelemetryConfig.OTLPProtocol

    var enabled: Bool
    var otlpProtocol: OTLPProtocol
    /// The collector URL per selected signal. For HTTP the signal path (`/v1/metrics`…)
    /// is already applied; for gRPC only host, port and scheme matter.
    var endpoints: [Signal: URL]
    var headers: [String: String]
    var exportInterval: TimeInterval
    var signals: Set<Signal>
    /// Final resource attributes, identity included.
    var resource: [String: String]
    var prometheus: TelemetryListenAddress?
    /// Extra dimensions on the job counters and histograms (see `TelemetryConfig.JobAttribute`).
    var jobAttributes: Set<KinhinConfig.TelemetryConfig.JobAttribute>
    /// Environment values that were set but unusable, and were ignored.
    var warnings: [String]

    /// Nothing runs: no exporter, no listener.
    static let disabled = TelemetrySettings(
        enabled: false, otlpProtocol: .httpProtobuf, endpoints: [:], headers: [:], exportInterval: 60, signals: [],
        resource: [:], prometheus: nil, jobAttributes: [], warnings: [])

    /// A line for the log: never the header values.
    var description: String {
        guard enabled else { return "telemetry disabled" }
        let signalNames = signals.map(\.rawValue).sorted().joined(separator: ",")
        let target = endpoints.keys.sorted { $0.rawValue < $1.rawValue }
            .compactMap { signal in endpoints[signal].map { "\(signal.rawValue)=\($0.absoluteString)" } }.joined(
                separator: " ")
        var parts = [
            "telemetry enabled", "protocol=\(otlpProtocol.rawValue)", "signals=\(signalNames)",
            "interval=\(Int(exportInterval))s",
        ]
        if !target.isEmpty { parts.append(target) }
        if !headers.isEmpty { parts.append("headers=\(headers.count) set") }
        if let prometheus { parts.append("prometheus=\(prometheus.host):\(prometheus.port)") }
        return parts.joined(separator: " ")
    }
}

/// The machine facts that seed the resource.
struct TelemetryHostInfo: Sendable, Equatable {
    var hostName: String
    var architecture: String
    var osVersion: String

    static var current: TelemetryHostInfo {
        #if arch(arm64)
            let arch = "arm64"
        #elseif arch(x86_64)
            let arch = "amd64"
        #else
            let arch = "unknown"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return TelemetryHostInfo(
            hostName: ProcessInfo.processInfo.hostName, architecture: arch,
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
}

enum TelemetryResolver {
    /// The `OTEL_*` variables kinhin honours (documented in docs/telemetry.md).
    static let supportedEnvironment = [
        "OTEL_SDK_DISABLED", "OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
        "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "OTEL_EXPORTER_OTLP_PROTOCOL",
        "OTEL_EXPORTER_OTLP_HEADERS", "OTEL_METRIC_EXPORT_INTERVAL", "OTEL_METRICS_EXPORTER", "OTEL_TRACES_EXPORTER",
        "OTEL_LOGS_EXPORTER", "OTEL_RESOURCE_ATTRIBUTES",
    ]

    /// Config + environment → settings. Environment wins for the settings it names;
    /// it never *enables* telemetry (only `telemetry.enabled: true` does) but
    /// `OTEL_SDK_DISABLED=true` always disables it.
    static func resolve(
        _ config: KinhinConfig.TelemetryConfig, environment: [String: String] = ProcessInfo.processInfo.environment,
        host: TelemetryHostInfo = .current, version: String = kinhinVersion.current
    ) -> TelemetrySettings {
        var warnings: [String] = []
        func env(_ name: String) -> String? {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
                return nil
            }
            return value
        }

        if let raw = env("OTEL_SDK_DISABLED")?.lowercased(), raw == "true" {
            return .disabled
        }
        guard config.enabled else { return .disabled }

        // Protocol.
        var otlpProtocol = config.otlpProtocol
        if let raw = env("OTEL_EXPORTER_OTLP_PROTOCOL") {
            if let parsed = TelemetrySettings.OTLPProtocol(rawValue: raw) {
                otlpProtocol = parsed
            } else {
                warnings.append("OTEL_EXPORTER_OTLP_PROTOCOL '\(raw)' is not http/protobuf or grpc; ignored")
            }
        }

        // Signals: config picks the set, `OTEL_<SIGNAL>_EXPORTER=none` removes one.
        var signals = config.signals
        for (signal, name) in [
            (TelemetrySettings.Signal.metrics, "OTEL_METRICS_EXPORTER"), (.traces, "OTEL_TRACES_EXPORTER"),
            (.logs, "OTEL_LOGS_EXPORTER"),
        ] where env(name)?.lowercased() == "none" {
            signals.remove(signal)
        }

        // Interval: OTEL_METRIC_EXPORT_INTERVAL is milliseconds.
        var interval = TimeInterval(config.exportIntervalSeconds)
        if let raw = env("OTEL_METRIC_EXPORT_INTERVAL") {
            if let ms = Double(raw), ms >= 1000, ms <= 3_600_000 {
                interval = ms / 1000
            } else {
                warnings.append("OTEL_METRIC_EXPORT_INTERVAL '\(raw)' is not 1000-3600000 ms; ignored")
            }
        }

        // Endpoints.
        let baseText = env("OTEL_EXPORTER_OTLP_ENDPOINT") ?? config.endpoint
        var base: URL?
        if let baseText {
            if let url = ConfigLoader.telemetryEndpointURL(baseText) {
                base = url
            } else {
                warnings.append("telemetry endpoint is not an http or https URL; using the default collector address")
            }
        }
        let fallback = defaultCollector(for: otlpProtocol)
        var endpoints: [TelemetrySettings.Signal: URL] = [:]
        for (signal, name) in [
            (TelemetrySettings.Signal.metrics, "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"),
            (.traces, "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"), (.logs, "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"),
        ] where signals.contains(signal) {
            if let raw = env(name) {
                if let url = ConfigLoader.telemetryEndpointURL(raw) {
                    endpoints[signal] = url
                    continue
                }
                warnings.append("\(name) is not an http or https URL; ignored")
            }
            endpoints[signal] = signalURL(base: base ?? fallback, signal: signal, otlpProtocol: otlpProtocol)
        }

        // Headers: environment only.
        let headers = parseHeaders(env("OTEL_EXPORTER_OTLP_HEADERS"))

        // Resource: SDK-style defaults < config < OTEL_RESOURCE_ATTRIBUTES < kinhin identity.
        var resource: [String: String] = [
            "host.name": host.hostName, "host.arch": host.architecture, "os.type": "darwin",
            "os.version": host.osVersion, "service.instance.id": host.hostName,
        ]
        for (key, value) in config.resourceAttributes where !KinhinConfig.TelemetryConfig.isReservedResourceKey(key) {
            resource[key] = value
        }
        for (key, value) in parseKeyValues(env("OTEL_RESOURCE_ATTRIBUTES")) {
            if KinhinConfig.TelemetryConfig.isReservedResourceKey(key) {
                warnings.append("OTEL_RESOURCE_ATTRIBUTES cannot set '\(key)': kinhin owns the service identity")
            } else {
                resource[key] = value
            }
        }
        if env("OTEL_SERVICE_NAME") != nil {
            warnings.append("OTEL_SERVICE_NAME is not honoured: the service name is always kinhin")
        }
        resource["service.name"] = "kinhin"
        resource["service.version"] = version

        let prometheus: TelemetryListenAddress? =
            signals.contains(.metrics) ? config.prometheusListen.flatMap { TelemetryListenAddress(parsing: $0) } : nil

        return TelemetrySettings(
            enabled: true, otlpProtocol: otlpProtocol, endpoints: endpoints, headers: headers,
            exportInterval: interval, signals: signals, resource: resource, prometheus: prometheus,
            jobAttributes: config.jobAttributes, warnings: warnings)
    }

    /// The collector on this Mac at the protocol's conventional port.
    static func defaultCollector(for otlpProtocol: TelemetrySettings.OTLPProtocol) -> URL {
        guard let url = URL(string: "http://localhost:\(otlpProtocol.defaultPort)") else {
            preconditionFailure("the default collector address is a valid URL")
        }
        return url
    }

    /// The per-signal URL under a base: HTTP appends the OTLP path, gRPC keeps the authority.
    static func signalURL(base: URL, signal: TelemetrySettings.Signal, otlpProtocol: TelemetrySettings.OTLPProtocol)
        -> URL
    {
        guard otlpProtocol == .httpProtobuf else { return base }
        let path: String
        switch signal {
        case .metrics: path = "v1/metrics"
        case .traces: path = "v1/traces"
        case .logs: path = "v1/logs"
        }
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: "\(text)/\(path)") ?? base
    }

    /// `k1=v1,k2=v2` with percent-encoded values (the OTEL list format).
    static func parseKeyValues(_ raw: String?) -> [String: String] {
        guard let raw else { return [:] }
        var out: [String: String] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            out[key] = value.removingPercentEncoding ?? value
        }
        return out
    }

    static func parseHeaders(_ raw: String?) -> [String: String] { parseKeyValues(raw) }
}
