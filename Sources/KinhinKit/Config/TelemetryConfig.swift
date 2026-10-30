import Foundation

extension KinhinConfig {
    /// Observability (`telemetry:`): metrics, traces and logs over OTLP, and
    /// an optional local Prometheus scrape endpoint. Off by default; while
    /// `enabled` is false kinhin starts no exporter and opens no listener.
    /// `logFormat` is independent of `enabled` (it only shapes the local log file).
    public struct TelemetryConfig: Sendable, Equatable {
        public enum OTLPProtocol: String, Sendable, CaseIterable {
            case httpProtobuf = "http/protobuf"
            case grpc

            /// The collector's conventional port for the protocol.
            var defaultPort: Int { self == .grpc ? 4317 : 4318 }
        }

        public enum Signal: String, Sendable, CaseIterable, Hashable {
            case metrics, traces, logs
        }

        /// A per-job dimension that can be added to the job counters and histograms. Off by default: in an
        /// org-scoped fleet repositories and workflows are unbounded, which costs a series each in Prometheus.
        public enum JobAttribute: String, Sendable, CaseIterable, Hashable {
            case repository, workflow
        }

        public enum LogFormat: String, Sendable, CaseIterable {
            /// The plain-text lines kinhin has always written.
            case text
            /// One JSON object per line, with VM, job, trace and span ids when known.
            case json
        }

        public var enabled: Bool
        /// Collector base URL; nil = `http://localhost:4318` (`:4317` for gRPC).
        public var endpoint: String?
        public var otlpProtocol: OTLPProtocol
        /// How often metrics (and batched spans and logs) are pushed.
        public var exportIntervalSeconds: Int
        public var signals: Set<Signal>
        /// Extra resource attributes. The identity keys (`service.name`,
        /// `service.version`, `telemetry.sdk.*`) belong to kinhin and are rejected here.
        public var resourceAttributes: [String: String]
        /// `host:port` (or a bare port, meaning loopback) of a local `/metrics`
        /// scrape endpoint; nil = no listener.
        public var prometheusListen: String?
        public var logFormat: LogFormat
        /// Extra dimensions on `cicd.pipeline.run.duration`, `kinhin.jobs.completed` and the queue-wait histogram.
        public var jobAttributes: Set<JobAttribute>
        /// Fraction of job traces recorded and exported, 0...1 (1 = all). Decided once per trace, at its root span.
        public var samplingRatio: Double
        /// The lowest severity forwarded to the OTLP log pipeline. Independent of the local log file and `Log.minLevel`.
        public var logLevel: Log.Level
        /// Name of a Keychain item holding a bearer token for the collector, sent as `Authorization: Bearer <token>`.
        /// The token itself is never in the config file.
        public var headersKeychain: String?
        /// Absolute path of a PEM CA bundle that signs the collector's certificate (replacing the system roots).
        public var caFile: String?
        /// Queue spans and log records on disk so they survive collector downtime and restarts.
        public var persist: Bool

        public init(
            enabled: Bool = false, endpoint: String? = nil, otlpProtocol: OTLPProtocol = .httpProtobuf,
            exportIntervalSeconds: Int = 60, signals: Set<Signal> = Set(Signal.allCases),
            resourceAttributes: [String: String] = [:], prometheusListen: String? = nil,
            logFormat: LogFormat = .text, jobAttributes: Set<JobAttribute> = [], samplingRatio: Double = 1,
            logLevel: Log.Level = .info, headersKeychain: String? = nil, caFile: String? = nil, persist: Bool = false
        ) {
            self.enabled = enabled
            self.endpoint = endpoint
            self.otlpProtocol = otlpProtocol
            self.exportIntervalSeconds = exportIntervalSeconds
            self.signals = signals
            self.resourceAttributes = resourceAttributes
            self.prometheusListen = prometheusListen
            self.logFormat = logFormat
            self.jobAttributes = jobAttributes
            self.samplingRatio = samplingRatio
            self.logLevel = logLevel
            self.headersKeychain = headersKeychain
            self.caFile = caFile
            self.persist = persist
        }

        public static let `default` = TelemetryConfig()

        /// The allowed range of `export_interval`, in seconds.
        static let exportIntervalRange = 1...3600

        /// Resource keys kinhin owns: user config cannot obscure the service identity.
        static let reservedResourceKeys: Set<String> = ["service.name", "service.version"]

        static func isReservedResourceKey(_ key: String) -> Bool {
            reservedResourceKeys.contains(key) || key.hasPrefix("telemetry.sdk.")
        }

        enum CodingKeys: String, CodingKey {
            case enabled, endpoint, signals
            case otlpProtocol = "protocol"
            case exportIntervalSeconds = "export_interval_seconds"
            case jobAttributes = "job_attributes"
            case resourceAttributes = "resource_attributes"
            case prometheusListen = "prometheus_listen"
            case logFormat = "log_format"
            case samplingRatio = "sampling_ratio"
            case logLevel = "log_level"
            case headersKeychain = "headers_keychain"
            case caFile = "ca_file"
            case persist
        }
    }
}

// MARK: - Listen address

/// A parsed `prometheus_listen` value.
struct TelemetryListenAddress: Sendable, Equatable {
    var host: String
    var port: Int

    static let loopbackHost = "127.0.0.1"

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Accepts `9464`, `host:port`, `127.0.0.1:9464`, `[::1]:9464`. A bare port binds loopback.
    init?(parsing raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let port = Int(text) {
            guard (1...65535).contains(port) else { return nil }
            self.host = Self.loopbackHost
            self.port = port
            return
        }
        let hostPart: Substring
        let portPart: Substring
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            hostPart = text[text.index(after: text.startIndex)..<close]
            let rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            portPart = rest.dropFirst()
        } else {
            let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return nil }
            hostPart = pieces[0]
            portPart = pieces[1]
        }
        guard !hostPart.isEmpty, hostPart.allSatisfy({ !$0.isWhitespace && $0 != "/" }),
            let port = Int(portPart), (1...65535).contains(port)
        else { return nil }
        self.host = String(hostPart)
        self.port = port
    }

    var isLoopback: Bool {
        ["127.0.0.1", "::1", "localhost"].contains(host.lowercased())
    }
}
