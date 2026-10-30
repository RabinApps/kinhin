import XCTest

@testable import KinhinKit

final class TelemetryConfigTests: XCTestCase {
    private let accounts = """
        accounts:
          - name: github
            forge: github
            scope: acme/widgets

        """

    func testOffByDefault() throws {
        let config = try ConfigLoader.parse(accounts)
        XCTAssertEqual(config.telemetry, .default)
        XCTAssertFalse(config.telemetry.enabled)
        XCTAssertNil(config.telemetry.prometheusListen)
        XCTAssertEqual(config.telemetry.logFormat, .text)
        XCTAssertEqual(config.telemetry.signals, Set(KinhinConfig.TelemetryConfig.Signal.allCases))
    }

    func testEveryKeyParses() throws {
        let config = try ConfigLoader.parse(
            accounts + """
                telemetry:
                  enabled: true
                  endpoint: https://collector.example.com:4317
                  protocol: grpc
                  export_interval: 15
                  signals: [metrics, traces]
                  resource_attributes:
                    deployment.environment: lab
                  prometheus_listen: 127.0.0.1:9464
                  log_format: json
                """)
        let telemetry = config.telemetry
        XCTAssertTrue(telemetry.enabled)
        XCTAssertEqual(telemetry.endpoint, "https://collector.example.com:4317")
        XCTAssertEqual(telemetry.otlpProtocol, .grpc)
        XCTAssertEqual(telemetry.exportIntervalSeconds, 15)
        XCTAssertEqual(telemetry.signals, [.metrics, .traces])
        XCTAssertEqual(telemetry.resourceAttributes, ["deployment.environment": "lab"])
        XCTAssertEqual(telemetry.prometheusListen, "127.0.0.1:9464")
        XCTAssertEqual(telemetry.logFormat, .json)
    }

    func testBadValuesAreRejectedByName() {
        let cases: [(String, String)] = [
            ("endpoint: not a url", "telemetry.endpoint"),
            ("endpoint: ftp://host", "telemetry.endpoint"),
            ("protocol: carrier-pigeon", "telemetry.protocol"),
            ("export_interval: 0", "telemetry.export_interval"),
            ("export_interval: 99999", "telemetry.export_interval"),
            ("signals: [metrics, spans]", "telemetry.signals"),
            ("prometheus_listen: nowhere", "telemetry.prometheus_listen"),
            ("prometheus_listen: 0.0.0.0:99999", "telemetry.prometheus_listen"),
            ("log_format: xml", "telemetry.log_format"),
            ("signals: [traces]\n  prometheus_listen: 9464", "telemetry.prometheus_listen"),
        ]
        for (body, key) in cases {
            XCTAssertThrowsError(try ConfigLoader.parse(accounts + "telemetry:\n  \(body)\n"), body) { error in
                XCTAssertTrue("\(error.localizedDescription)".contains(key), "\(body): \(error.localizedDescription)")
            }
        }
    }

    func testServiceIdentityCannotBeSetByConfig() {
        for key in ["service.name", "service.version", "telemetry.sdk.language"] {
            XCTAssertThrowsError(
                try ConfigLoader.parse(accounts + "telemetry:\n  resource_attributes:\n    \(key): x\n")
            ) { error in
                XCTAssertTrue("\(error.localizedDescription)".contains(key), error.localizedDescription)
            }
        }
    }

    func testUnknownKeyIsReported() {
        XCTAssertThrowsError(try ConfigLoader.parse(accounts + "telemetry:\n  enable: true\n")) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("telemetry.enable"))
        }
    }

    func testBareListenPortBindsLoopback() throws {
        let address = try XCTUnwrap(TelemetryListenAddress(parsing: "9464"))
        XCTAssertEqual(address, TelemetryListenAddress(host: "127.0.0.1", port: 9464))
        XCTAssertTrue(address.isLoopback)
        XCTAssertEqual(TelemetryListenAddress(parsing: "[::1]:9000")?.host, "::1")
        XCTAssertFalse(try XCTUnwrap(TelemetryListenAddress(parsing: "0.0.0.0:9000")).isLoopback)
        XCTAssertNil(TelemetryListenAddress(parsing: ":9000"))
    }

    func testTemplateDocumentsTelemetryAndStillParses() throws {
        XCTAssertTrue(ConfigLoader.template().contains("telemetry:"))
        XCTAssertFalse(try ConfigLoader.parse(ConfigLoader.template()).telemetry.enabled)
    }

    func testTelemetryChangeDoesNotRequireAnEngineRebuild() throws {
        let old = try ConfigLoader.parse(accounts)
        let new = try ConfigLoader.parse(accounts + "telemetry:\n  enabled: true\n")
        XCTAssertFalse(FleetEngine.restartRequired(from: old, to: new))
    }
}
