import Foundation
import XCTest

@testable import KinhinKit

/// Config validation of `sampling_ratio`, `log_level`, `headers_keychain`, `ca_file` and `persist`.
final class TelemetryExporterKeysTests: XCTestCase {
    private let accounts = "accounts:\n  - name: github\n    forge: github\n    scope: acme/widgets\n"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)  // temp directory cleanup
    }

    private func parse(_ body: String) throws -> KinhinConfig.TelemetryConfig {
        try ConfigLoader.parse(accounts + "telemetry:\n  \(body)\n").telemetry
    }

    private func caFile(_ text: String) throws -> String {
        let url = directory.appendingPathComponent("ca.pem")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testDefaults() throws {
        let telemetry = try ConfigLoader.parse(accounts).telemetry
        XCTAssertEqual(telemetry.samplingRatio, 1)
        XCTAssertEqual(telemetry.logLevel, .info)
        XCTAssertNil(telemetry.headersKeychain)
        XCTAssertNil(telemetry.caFile)
        XCTAssertFalse(telemetry.persist, "persistence is opt-in")
    }

    func testEveryKeyParses() throws {
        let path = try caFile(TelemetryTLSFixtures.caOne)
        let telemetry = try parse(
            "sampling_ratio: 0.1\n  log_level: warn\n  headers_keychain: grafana-cloud\n  ca_file: \(path)\n  persist: true"
        )
        XCTAssertEqual(telemetry.samplingRatio, 0.1)
        XCTAssertEqual(telemetry.logLevel, .warn)
        XCTAssertEqual(telemetry.headersKeychain, "grafana-cloud")
        XCTAssertEqual(telemetry.caFile, path)
        XCTAssertTrue(telemetry.persist)
        XCTAssertEqual(try parse("sampling_ratio: 0").samplingRatio, 0)
        XCTAssertEqual(try parse("sampling_ratio: 1").samplingRatio, 1)
        for level in ["debug", "info", "warn", "error"] {
            XCTAssertEqual(try parse("log_level: \(level)").logLevel.rawValue, level)
        }
    }

    func testBadValuesNameTheirKey() throws {
        let garbage = try caFile("this is not a certificate")
        let cases: [(String, String)] = [
            ("sampling_ratio: 1.5", "telemetry.sampling_ratio"),
            ("sampling_ratio: -0.1", "telemetry.sampling_ratio"),
            ("sampling_ratio: .nan", "telemetry.sampling_ratio"),
            ("sampling_ratio: lots", "telemetry.sampling_ratio"),
            ("log_level: trace", "telemetry.log_level"),
            ("log_level: WARN", "telemetry.log_level"),
            ("headers_keychain: \"\"", "telemetry.headers_keychain"),
            ("headers_keychain: \"two words\"", "telemetry.headers_keychain"),
            ("headers_keychain: \"a:b\"", "telemetry.headers_keychain"),
            ("ca_file: relative/ca.pem", "telemetry.ca_file"),
            ("ca_file: \(directory.path)/missing.pem", "telemetry.ca_file"),
            ("ca_file: \(garbage)", "telemetry.ca_file"),
            ("persist: maybe", "persist"),
        ]
        for (body, key) in cases {
            XCTAssertThrowsError(try parse(body), body) { error in
                XCTAssertTrue("\(error.localizedDescription)".contains(key), "\(body): \(error.localizedDescription)")
            }
        }
    }

    func testCAFileTildeExpandsToAnAbsolutePath() throws {
        // `~` resolves before the file is read, so a missing home-relative file is reported with its full path.
        XCTAssertThrowsError(try parse("ca_file: ~/definitely-not-here-\(UUID().uuidString).pem")) { error in
            XCTAssertTrue(error.localizedDescription.contains(NSHomeDirectory()), error.localizedDescription)
        }
    }

    func testTemplateMentionsTheNewKeysAndStillParses() throws {
        let template = ConfigLoader.template()
        for key in ["sampling_ratio", "log_level", "headers_keychain", "ca_file", "persist"] {
            XCTAssertTrue(template.contains(key), key)
        }
        XCTAssertFalse(try ConfigLoader.parse(template).telemetry.enabled)
    }

    func testSettingsCarryTheKeys() {
        let settings = TelemetryResolver.resolve(
            KinhinConfig.TelemetryConfig(enabled: true, logLevel: .error, persist: true), environment: [:],
            host: TelemetryHostInfo(hostName: "h", architecture: "arm64", osVersion: "26.0.0"))
        XCTAssertEqual(settings.logLevel, .error)
        XCTAssertTrue(settings.persist)
        XCTAssertTrue(settings.description.contains("persist=on"), settings.description)
        XCTAssertTrue(settings.description.contains("log_level=error"), settings.description)
    }
}
