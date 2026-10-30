import Foundation
import Security
import XCTest

@testable import KinhinKit

/// The pure parts of `telemetry.ca_file` / `OTEL_EXPORTER_OTLP_CERTIFICATE`: PEM parsing, the trust decision against
/// the configured CA alone, and settings resolution. A real TLS handshake against a listener is not covered here.
final class TelemetryTLSTests: XCTestCase {
    private typealias Fixtures = TelemetryTLSFixtures
    private let host = TelemetryHostInfo(hostName: "h", architecture: "arm64", osVersion: "26.0.0")
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)  // temp directory cleanup
    }

    private func write(_ text: String, name: String = "ca.pem") throws -> String {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func certificate(_ pem: String) throws -> SecCertificate {
        try XCTUnwrap(TelemetryCABundle.certificates(fromPEM: Data(pem.utf8)).first)
    }

    private func trust(for pem: String, host: String = "localhost") throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            try certificate(pem), SecPolicyCreateSSL(true, host as CFString), &trust)
        XCTAssertEqual(status, errSecSuccess)
        return try XCTUnwrap(trust)
    }

    // MARK: - Parsing

    func testParsesASingleCertificateAndABundle() throws {
        XCTAssertEqual(try TelemetryCABundle.certificates(fromPEM: Data(Fixtures.caOne.utf8)).count, 1)
        let bundle = "# comment\n\(Fixtures.caOne)\n\nnoise between\n\(Fixtures.caTwo)\n"
        XCTAssertEqual(try TelemetryCABundle.certificates(fromPEM: Data(bundle.utf8)).count, 2)
    }

    func testRejectsFilesWithoutAUsableCertificate() throws {
        XCTAssertThrowsError(try TelemetryCABundle.certificates(fromPEM: Data("hello".utf8))) {
            XCTAssertEqual($0 as? TelemetryCABundle.Problem, .noCertificates("the CA file"))
        }
        XCTAssertThrowsError(try TelemetryCABundle.certificates(fromPEM: Data()))
        let broken = "-----BEGIN CERTIFICATE-----\nnot base64 at all!!\n-----END CERTIFICATE-----\n"
        XCTAssertThrowsError(try TelemetryCABundle.certificates(fromPEM: Data(broken.utf8))) {
            XCTAssertEqual($0 as? TelemetryCABundle.Problem, .invalidCertificate("the CA file"))
        }
        let notDER = "-----BEGIN CERTIFICATE-----\naGVsbG8=\n-----END CERTIFICATE-----\n"
        XCTAssertThrowsError(try TelemetryCABundle.certificates(fromPEM: Data(notDER.utf8)))
    }

    func testLoadReadsAFileAndNamesTheProblem() throws {
        XCTAssertEqual(try TelemetryCABundle.load(path: try write(Fixtures.caOne)).count, 1)
        let missing = directory.appendingPathComponent("missing.pem").path
        XCTAssertThrowsError(try TelemetryCABundle.load(path: missing)) {
            XCTAssertTrue($0.localizedDescription.contains(missing), $0.localizedDescription)
        }
        XCTAssertThrowsError(try TelemetryCABundle.load(path: "relative/ca.pem")) {
            XCTAssertEqual($0 as? TelemetryCABundle.Problem, .notAbsolute("relative/ca.pem"))
        }
        XCTAssertTrue(try TelemetryCABundle.resolvedPath("~/ca.pem").hasPrefix("/"))
    }

    // MARK: - Trust

    func testAcceptsAServerSignedByTheConfiguredCA() throws {
        let anchors = try TelemetryCABundle.certificates(fromPEM: Data(Fixtures.caOne.utf8))
        XCTAssertTrue(
            TelemetryCABundle.evaluate(
                trust: try trust(for: Fixtures.leafSignedByCAOne), anchors: anchors, verifyDate: Fixtures.verifyDate))
    }

    func testRejectsAServerSignedByAnotherCA() throws {
        let anchors = try TelemetryCABundle.certificates(fromPEM: Data(Fixtures.caTwo.utf8))
        XCTAssertFalse(
            TelemetryCABundle.evaluate(
                trust: try trust(for: Fixtures.leafSignedByCAOne), anchors: anchors, verifyDate: Fixtures.verifyDate))
    }

    func testRejectsTheRightCAForTheWrongHostname() throws {
        let anchors = try TelemetryCABundle.certificates(fromPEM: Data(Fixtures.caOne.utf8))
        XCTAssertFalse(
            TelemetryCABundle.evaluate(
                trust: try trust(for: Fixtures.leafSignedByCAOne, host: "collector.example.com"), anchors: anchors,
                verifyDate: Fixtures.verifyDate))
    }

    func testRejectsAnExpiredChain() throws {
        let anchors = try TelemetryCABundle.certificates(fromPEM: Data(Fixtures.caOne.utf8))
        let longAfter = Date(timeIntervalSince1970: 2_500_000_000)  // 2049
        XCTAssertFalse(
            TelemetryCABundle.evaluate(
                trust: try trust(for: Fixtures.leafSignedByCAOne), anchors: anchors, verifyDate: longAfter))
    }

    func testAnEmptyAnchorSetTrustsNothing() throws {
        XCTAssertFalse(
            TelemetryCABundle.evaluate(
                trust: try trust(for: Fixtures.leafSignedByCAOne), anchors: [], verifyDate: Fixtures.verifyDate))
    }

    // MARK: - Transport

    func testTransportRefusesAnUnusableCAFile() throws {
        var settings = TelemetryResolver.resolve(
            KinhinConfig.TelemetryConfig(enabled: true), environment: [:], host: host)
        settings.caFile = try write("not a certificate", name: "bad.pem")
        XCTAssertThrowsError(try TelemetryTransport(settings: settings, queueRoot: directory)) {
            guard case TelemetryError.badCAFile = $0 else { return XCTFail("\($0)") }
        }
        settings.caFile = try write(Fixtures.caOne)
        XCTAssertNoThrow(try TelemetryTransport(settings: settings, queueRoot: directory).invalidate())
    }

    /// The environment path is resolved like `ca_file` (so gRPC, which reads `settings.caFile` as is, gets a real path).
    func testEnvironmentCertificateIsResolvedAndMustBeAbsolute() {
        let config = KinhinConfig.TelemetryConfig(enabled: true, endpoint: "https://collector:4317")
        let home = TelemetryResolver.resolve(
            config, environment: ["OTEL_EXPORTER_OTLP_CERTIFICATE": "~/ca.pem"], host: host)
        XCTAssertEqual(home.caFile, (("~/ca.pem") as NSString).expandingTildeInPath)
        let relative = TelemetryResolver.resolve(
            config, environment: ["OTEL_EXPORTER_OTLP_CERTIFICATE": "ca.pem"], host: host)
        XCTAssertEqual(relative.caFile, "ca.pem", "kept as given, so starting telemetry fails closed")
        XCTAssertThrowsError(try TelemetryTransport(settings: relative, queueRoot: directory)) {
            XCTAssertTrue("\($0)".contains("ca.pem"), "\($0)")
        }
    }

    func testEnvironmentCertificateOverridesTheConfigAndNeedsAnHTTPSEndpoint() {
        var config = KinhinConfig.TelemetryConfig(enabled: true, endpoint: "https://collector:4318")
        config.caFile = "/from/config.pem"
        let overridden = TelemetryResolver.resolve(
            config, environment: ["OTEL_EXPORTER_OTLP_CERTIFICATE": "/from/env.pem"], host: host)
        XCTAssertEqual(overridden.caFile, "/from/env.pem")
        XCTAssertEqual(TelemetryResolver.resolve(config, environment: [:], host: host).caFile, "/from/config.pem")
        XCTAssertTrue(overridden.warnings.isEmpty, "\(overridden.warnings)")

        config.endpoint = "http://collector:4318"
        let plain = TelemetryResolver.resolve(config, environment: [:], host: host)
        XCTAssertEqual(plain.warnings.count, 1, "a CA file is pointless without https: \(plain.warnings)")
        XCTAssertTrue(plain.description.contains("ca=custom"))
        XCTAssertFalse(plain.description.contains("config.pem"))
    }
}
