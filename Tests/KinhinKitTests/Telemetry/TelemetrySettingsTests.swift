import XCTest

@testable import KinhinKit

final class TelemetrySettingsTests: XCTestCase {
    private let host = TelemetryHostInfo(hostName: "mac-mini", architecture: "arm64", osVersion: "26.0.0")

    private func resolve(
        _ config: KinhinConfig.TelemetryConfig, env: [String: String] = [:]
    ) -> TelemetrySettings {
        TelemetryResolver.resolve(config, environment: env, host: host, version: "9.9.9")
    }

    private var enabled: KinhinConfig.TelemetryConfig { KinhinConfig.TelemetryConfig(enabled: true) }

    func testDisabledByDefaultAndEnvCannotEnable() {
        XCTAssertFalse(resolve(.default).enabled)
        let env = ["OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4318", "OTEL_RESOURCE_ATTRIBUTES": "a=b"]
        XCTAssertEqual(resolve(.default, env: env), .disabled)
    }

    func testSDKDisabledWinsOverConfig() {
        XCTAssertEqual(resolve(enabled, env: ["OTEL_SDK_DISABLED": "true"]), .disabled)
        XCTAssertTrue(resolve(enabled, env: ["OTEL_SDK_DISABLED": "false"]).enabled)
    }

    func testDefaultEndpointsPerProtocol() throws {
        let http = resolve(enabled)
        XCTAssertEqual(http.endpoints[.metrics]?.absoluteString, "http://localhost:4318/v1/metrics")
        XCTAssertEqual(http.endpoints[.traces]?.absoluteString, "http://localhost:4318/v1/traces")
        XCTAssertEqual(http.endpoints[.logs]?.absoluteString, "http://localhost:4318/v1/logs")
        var grpc = enabled
        grpc.otlpProtocol = .grpc
        XCTAssertEqual(resolve(grpc).endpoints[.traces]?.absoluteString, "http://localhost:4317")
    }

    func testEnvironmentOverridesConfig() {
        var config = enabled
        config.endpoint = "http://from-config:4318/"
        config.exportIntervalSeconds = 30
        config.signals = [.metrics, .traces, .logs]
        let settings = resolve(
            config,
            env: [
                "OTEL_EXPORTER_OTLP_ENDPOINT": "https://from-env:4318", "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
                "OTEL_METRIC_EXPORT_INTERVAL": "5000", "OTEL_LOGS_EXPORTER": "none",
                "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "https://traces.example/custom",
            ])
        XCTAssertEqual(settings.otlpProtocol, .grpc)
        XCTAssertEqual(settings.exportInterval, 5)
        XCTAssertEqual(settings.signals, [.metrics, .traces])
        XCTAssertEqual(settings.endpoints[.metrics]?.absoluteString, "https://from-env:4318")
        XCTAssertEqual(settings.endpoints[.traces]?.absoluteString, "https://traces.example/custom")
        XCTAssertNil(settings.endpoints[.logs])
    }

    func testConfigEndpointIsUsedWithoutEnvironment() {
        var config = enabled
        config.endpoint = "http://from-config:4318/"
        XCTAssertEqual(resolve(config).endpoints[.metrics]?.absoluteString, "http://from-config:4318/v1/metrics")
    }

    func testUnusableEnvironmentValuesAreIgnoredWithAWarning() {
        let settings = resolve(
            enabled, env: ["OTEL_EXPORTER_OTLP_PROTOCOL": "smoke-signals", "OTEL_METRIC_EXPORT_INTERVAL": "12"])
        XCTAssertEqual(settings.otlpProtocol, .httpProtobuf)
        XCTAssertEqual(settings.exportInterval, 60)
        XCTAssertEqual(settings.warnings.count, 2, "\(settings.warnings)")
    }

    func testResourceMergeKeepsServiceIdentity() {
        var config = enabled
        config.resourceAttributes = ["deployment.environment": "lab", "host.name": "from-config"]
        let settings = resolve(
            config,
            env: [
                "OTEL_RESOURCE_ATTRIBUTES": "team=ci,service.name=evil,host.name=from-env",
                "OTEL_SERVICE_NAME": "other",
            ])
        XCTAssertEqual(settings.resource["service.name"], "kinhin")
        XCTAssertEqual(settings.resource["service.version"], "9.9.9")
        XCTAssertEqual(settings.resource["deployment.environment"], "lab")
        XCTAssertEqual(settings.resource["team"], "ci")
        // Defaults < config < OTEL_RESOURCE_ATTRIBUTES.
        XCTAssertEqual(settings.resource["host.name"], "from-env")
        XCTAssertEqual(settings.resource["host.arch"], "arm64")
        XCTAssertEqual(settings.resource["os.version"], "26.0.0")
        XCTAssertEqual(settings.warnings.count, 2, "\(settings.warnings)")
    }

    func testHeadersComeFromTheEnvironmentAndNeverAppearInTheDescription() {
        let settings = resolve(
            enabled, env: ["OTEL_EXPORTER_OTLP_HEADERS": "authorization=Bearer s3cret-value,x-team=a"])
        XCTAssertEqual(settings.headers["authorization"], "Bearer s3cret-value")
        XCTAssertFalse(settings.description.contains("s3cret"))
        XCTAssertTrue(settings.description.contains("headers=2"))
    }

    func testPrometheusNeedsTheMetricsSignal() {
        var config = enabled
        config.prometheusListen = "9464"
        XCTAssertEqual(resolve(config).prometheus?.port, 9464)
        config.signals = [.traces]
        XCTAssertNil(resolve(config).prometheus)
    }
}
