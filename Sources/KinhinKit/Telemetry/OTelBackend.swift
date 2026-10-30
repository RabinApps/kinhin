import Foundation
import GRPC
import NIOCore
import NIOPosix
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetryProtocolExporterGrpc
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk
import PrometheusExporter
import Synchronization

/// The OpenTelemetry SDK behind `TelemetryBackend`: OTLP (HTTP/protobuf or gRPC) exporters for
/// the selected signals and, optionally, a Prometheus reader served by `PrometheusListener`.
/// Everything SDK-specific is confined to this file, so the engine never imports it.
///
/// An instance owns its providers, channels and listener outright; `shutdown()` flushes and
/// releases all of them, which is what lets `TelemetryService` swap backends on a reload
/// without leaking exporters or leaving a port bound.
final class OTelBackend: TelemetryBackend, @unchecked Sendable {
    /// Histogram buckets for durations in seconds (the SDK default is millisecond-shaped).
    static let secondsBuckets: [Double] = [0.1, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600, 1800, 3600]

    private let settings: TelemetrySettings
    private var meterProvider: MeterProviderSdk?
    private var tracerProvider: TracerProviderSdk?
    private var loggerProvider: LoggerProviderSdk?
    private var logProcessor: BatchLogRecordProcessor?
    private var tracer: (any Tracer)?
    private var logger: (any OpenTelemetryApi.Logger)?
    private var prometheusReader: PeriodicMetricReaderSdk?
    private var prometheusListener: PrometheusListener?
    private var channels: [GRPCChannel] = []
    private var eventLoops: MultiThreadedEventLoopGroup?
    private let transport: TelemetryTransport

    private var counters: [String: LongCounterSdk] = [:]
    private var histograms: [String: DoubleHistogramMeterSdk] = [:]
    private let gaugeStore = Locked<[String: [GaugeSeries]]>([:])
    private var observableGauges: [any ObservableDoubleGauge] = []

    /// The port the Prometheus endpoint bound (0 when there is none); tests read it for an ephemeral port.
    var prometheusPort: Int { prometheusListener?.port ?? 0 }

    /// `queueRoot` is where `telemetry.persist` keeps its on-disk queue (a test points it at a temp directory).
    init(
        settings: TelemetrySettings, queueRoot: URL = Paths.appSupport.appendingPathComponent("telemetry-queue")
    ) throws {
        self.settings = settings
        transport = try TelemetryTransport(settings: settings, queueRoot: queueRoot)
        var resourceAttributes: [String: AttributeValue] = [:]
        for (key, value) in settings.resource { resourceAttributes[key] = .string(value) }
        // SDK defaults (telemetry.sdk.*) first, kinhin's attributes over them.
        let resource = Resource().merging(other: Resource(attributes: resourceAttributes))
        let headers = settings.headers.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        let configuration = OtlpConfiguration(headers: headers.isEmpty ? nil : headers)
        // Exporter credentials must never reach a log line, whoever prints one.
        for value in settings.headers.values { LogRedactor.registerSecret(value) }

        if settings.signals.contains(.metrics) {
            try buildMetrics(resource: resource, configuration: configuration)
        }
        if settings.signals.contains(.traces), let endpoint = settings.endpoints[.traces] {
            var exporter: SpanExporter
            switch settings.otlpProtocol {
            case .httpProtobuf:
                exporter = OtlpHttpTraceExporter(
                    endpoint: endpoint, config: configuration, httpClient: transport.httpClient, envVarHeaders: nil,
                    requeueOnFailure: !transport.persist)
            case .grpc:
                exporter = OtlpTraceExporter(
                    channel: try channel(for: endpoint), config: configuration, envVarHeaders: nil)
            }
            exporter = try transport.wrap(exporter)
            let provider = TracerProviderBuilder()
                .with(resource: resource)
                .with(sampler: settings.sampler.sdkSampler)
                .add(spanProcessor: BatchSpanProcessor(spanExporter: exporter, scheduleDelay: settings.exportInterval))
                .build()
            tracerProvider = provider
            tracer = provider.get(instrumentationName: "kinhin", instrumentationVersion: kinhinVersion.current)
        }
        if settings.signals.contains(.logs), let endpoint = settings.endpoints[.logs] {
            var exporter: LogRecordExporter
            switch settings.otlpProtocol {
            case .httpProtobuf:
                exporter = OtlpHttpLogExporter(
                    endpoint: endpoint, config: configuration, httpClient: transport.httpClient, envVarHeaders: nil,
                    requeueOnFailure: !transport.persist)
            case .grpc:
                exporter = OtlpLogExporter(
                    channel: try channel(for: endpoint), config: configuration, envVarHeaders: nil)
            }
            exporter = try transport.wrap(exporter)
            let processor = BatchLogRecordProcessor(logRecordExporter: exporter, scheduleDelay: settings.exportInterval)
            logProcessor = processor
            let provider = LoggerProviderBuilder().with(resource: resource).with(processors: [processor]).build()
            loggerProvider = provider
            logger = provider.get(instrumentationScopeName: "kinhin")
        }
    }

    // MARK: - Setup

    private func buildMetrics(resource: Resource, configuration: OtlpConfiguration) throws {
        // The SDK's entry builder only becomes a real one when the first reader is registered.
        let entry = MeterProviderSdk.builder().setResource(resource: resource)
        var readers: [MetricReader] = []
        var builder: MeterProviderBuilder?
        func register(_ reader: MetricReader) {
            builder = builder?.registerMetricReader(reader: reader) ?? entry.registerMetricReader(reader: reader)
        }
        for name in Metric.Histogram.allCases.map(\.rawValue) {
            let selector = InstrumentSelector.builder().setInstrument(name: name).build()
            let view = View.builder()
                .withAggregation(aggregation: ExplicitBucketHistogramAggregation(bucketBoundaries: Self.secondsBuckets))
                .build()
            _ = entry.registerView(selector: selector, view: view)
        }
        // Once any view is registered the SDK drops instruments no view selects, so counters and gauges
        // get explicit default-aggregation views too.
        let others = Metric.Counter.allCases.map(\.rawValue) + Metric.Gauge.allCases.map(\.rawValue)
        for name in others {
            _ = entry.registerView(
                selector: InstrumentSelector.builder().setInstrument(name: name).build(), view: View.builder().build())
        }
        if let endpoint = settings.endpoints[.metrics] {
            let exporter: MetricExporter
            switch settings.otlpProtocol {
            case .httpProtobuf:
                exporter = OtlpHttpMetricExporter(
                    endpoint: endpoint, config: configuration, httpClient: transport.httpClient, envVarHeaders: nil)
            case .grpc:
                exporter = OtlpMetricExporter(
                    channel: try channel(for: endpoint), config: configuration, envVarHeaders: nil)
            }
            readers.append(
                PeriodicMetricReaderBuilder(exporter: exporter).setInterval(timeInterval: settings.exportInterval)
                    .build())
        }
        var prometheusExporter: PrometheusExporter?
        if settings.prometheus != nil {
            let exporter = PrometheusExporter(options: PrometheusExporterOptions(url: "http://localhost"))
            // The exporter keeps the last collection; every scrape forces a fresh one (see `scrape`).
            let reader = PeriodicMetricReaderBuilder(exporter: exporter).setInterval(timeInterval: 3600).build()
            readers.append(reader)
            prometheusReader = reader
            prometheusExporter = exporter
        }
        for reader in readers { register(reader) }
        guard let provider = builder?.build() else { return }
        meterProvider = provider
        let meter = provider.get(name: "kinhin")
        for counter in Metric.Counter.allCases {
            counters[counter.rawValue] = meter.counterBuilder(name: counter.rawValue).build()
        }
        for histogram in Metric.Histogram.allCases {
            histograms[histogram.rawValue] =
                meter.histogramBuilder(name: histogram.rawValue).build()
        }
        for gauge in Metric.Gauge.allCases {
            let name = gauge.rawValue
            observableGauges.append(
                meter.gaugeBuilder(name: name).buildWithCallback { [gaugeStore] measurement in
                    for series in gaugeStore.withLock({ $0[name] ?? [] }) {
                        measurement.record(value: series.value, attributes: Self.attributes(series.attributes))
                    }
                })
        }
        if let address = settings.prometheus, let prometheusExporter {
            prometheusListener = try PrometheusListener(address: address) { [weak self] in
                self?.scrape(exporter: prometheusExporter) ?? ""
            }
        }
    }

    /// Renders the Prometheus text for one scrape from a fresh collection.
    private func scrape(exporter: PrometheusExporter) -> String {
        _ = prometheusReader?.forceFlush()
        return PrometheusExporterExtensions.writeMetricsCollection(exporter: exporter)
    }

    /// One gRPC channel to the collector's host and port (TLS for an https endpoint).
    private func channel(for endpoint: URL) throws -> GRPCChannel {
        guard let host = endpoint.host else { throw TelemetryError.badEndpoint(endpoint.absoluteString) }
        let useTLS = endpoint.scheme?.lowercased() == "https"
        let port = endpoint.port ?? (useTLS ? 443 : TelemetrySettings.OTLPProtocol.grpc.defaultPort)
        let group = eventLoops ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        eventLoops = group
        let builder: ClientConnection.Builder
        if useTLS, let caFile = settings.caFile {
            // Only the configured CA is trusted, as for HTTP (the file was parsed when the transport was built).
            builder = ClientConnection.usingTLSBackedByNIOSSL(on: group).withTLS(trustRoots: .file(caFile))
        } else if useTLS {
            builder = ClientConnection.usingPlatformAppropriateTLS(for: group)
        } else {
            builder = ClientConnection.insecure(group: group)
        }
        let channel = builder.connect(host: host, port: port)
        channels.append(channel)
        return channel
    }

    static func attributes(_ attributes: MetricAttributes) -> [String: AttributeValue] {
        attributes.mapValues { .string($0) }
    }

    static func value(_ value: TelemetryValue) -> AttributeValue {
        switch value {
        case .string(let text): return .string(text)
        case .int(let number): return .int(number)
        case .double(let number): return .double(number)
        case .bool(let flag): return .bool(flag)
        }
    }

    // MARK: - TelemetryBackend

    func add(counter name: String, value: Int, attributes: MetricAttributes) {
        counters[name]?.add(value: value, attributes: Self.attributes(attributes))
    }

    func record(histogram name: String, seconds: Double, attributes: MetricAttributes) {
        histograms[name]?.record(value: seconds, attributes: Self.attributes(attributes))
    }

    func publish(gauge name: String, series: [GaugeSeries]) {
        gaugeStore.withLock { $0[name] = series }
    }

    func startSpan(_ name: String, start: Date?, attributes: TelemetryAttributes) -> any TelemetrySpan {
        guard let tracer else { return NoopSpan() }
        let builder = tracer.spanBuilder(spanName: name)
        if let start { builder.setStartTime(time: start) }
        for (key, value) in attributes { builder.setAttribute(key: key, value: Self.value(value)) }
        let span = builder.startSpan()
        // A root the sampler dropped is not recorded, and neither is anything under it: its children must not
        // become roots of their own (the SDK would sample them afresh), so the whole trace is a no-op.
        guard span.isRecording else { return NoopSpan() }
        return OTelSpan(span: span, tracer: tracer)
    }

    func emit(log record: TelemetryLogRecord) {
        guard let logger else { return }
        var attributes: [String: AttributeValue] = ["kinhin.component": .string(record.component)]
        for (key, value) in record.attributes { attributes[key] = .string(value) }
        var builder = logger.logRecordBuilder()
            .setTimestamp(record.timestamp)
            .setBody(.string(record.message))
            .setSeverity(Self.severity(record.level))
            .setAttributes(attributes)
        if let trace = record.trace, let context = Self.spanContext(trace) {
            builder = builder.setSpanContext(context)
        }
        builder.emit()
    }

    func releaseListeners() {
        prometheusListener?.stop()
        prometheusListener = nil
    }

    func shutdown() async {
        // Order: stop accepting scrapes, then flush each pipeline, then drop the transports.
        releaseListeners()
        _ = meterProvider?.forceFlush()
        _ = meterProvider?.shutdown()
        tracerProvider?.forceFlush()
        tracerProvider?.shutdown()
        logProcessor?.forceFlush()
        _ = logProcessor?.shutdown(explicitTimeout: 5)
        // Best effort on the way out: a channel that fails to close cleanly is dropped with its event loop anyway.
        for channel in channels { try? await channel.close().get() }
        channels = []
        // Best effort on the way out, as above.
        if let group = eventLoops { try? await group.shutdownGracefully() }
        eventLoops = nil
        transport.invalidate()
    }

    // MARK: - Mapping

    static func severity(_ level: Log.Level) -> Severity {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .warn: return .warn
        case .error: return .error
        }
    }

    static func spanContext(_ context: TelemetrySpanContext) -> SpanContext? {
        guard context.traceID.count == 32, context.spanID.count == 16 else { return nil }
        return SpanContext.create(
            traceId: TraceId(fromHexString: context.traceID), spanId: SpanId(fromHexString: context.spanID),
            traceFlags: TraceFlags().settingIsSampled(true), traceState: TraceState())
    }
}

/// A span in the SDK. The SDK's span is internally synchronised, so sharing the wrapper is safe.
private final class OTelSpan: TelemetrySpan, @unchecked Sendable {
    private let span: any Span
    private let tracer: any Tracer

    init(span: any Span, tracer: any Tracer) {
        self.span = span
        self.tracer = tracer
    }

    var context: TelemetrySpanContext? {
        let context = span.context
        return TelemetrySpanContext(traceID: context.traceId.hexString, spanID: context.spanId.hexString)
    }

    func setAttributes(_ attributes: TelemetryAttributes) {
        for (key, value) in attributes { span.setAttribute(key: key, value: OTelBackend.value(value)) }
    }

    func startChild(_ name: String, start: Date?, attributes: TelemetryAttributes) -> any TelemetrySpan {
        let builder = tracer.spanBuilder(spanName: name).setParent(span)
        if let start { builder.setStartTime(time: start) }
        for (key, value) in attributes { builder.setAttribute(key: key, value: OTelBackend.value(value)) }
        let child = builder.startSpan()
        return child.isRecording ? OTelSpan(span: child, tracer: tracer) : NoopSpan()
    }

    func end(at: Date?, error: String?) {
        if let error { span.status = .error(description: LogRedactor.redact(error)) }
        if let at { span.end(time: at) } else { span.end() }
    }
}

enum TelemetryError: LocalizedError {
    case badEndpoint(String)
    case listenFailed(String)
    case badCAFile(String)
    case queueUnavailable(String, String)

    var errorDescription: String? {
        switch self {
        case .badEndpoint(let endpoint): return "telemetry endpoint '\(endpoint)' has no host"
        case .listenFailed(let reason): return "could not start the Prometheus endpoint: \(reason)"
        case .badCAFile(let reason): return "the collector CA file is unusable: \(reason)"
        case .queueUnavailable(let path, let reason):
            return "telemetry.persist: cannot use the queue directory \(path): \(reason)"
        }
    }
}

extension TelemetrySampler {
    /// The SDK sampler that makes this decision.
    var sdkSampler: Sampler {
        switch self {
        case .alwaysOn: return Samplers.alwaysOn
        case .alwaysOff: return Samplers.alwaysOff
        case .traceIDRatio(let ratio): return Samplers.traceIdRatio(ratio: ratio)
        case .parentBasedTraceIDRatio(let ratio):
            return Samplers.parentBased(root: Samplers.traceIdRatio(ratio: ratio))
        }
    }
}
