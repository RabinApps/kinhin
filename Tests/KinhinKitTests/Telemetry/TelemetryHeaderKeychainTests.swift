import Foundation
import XCTest

@testable import KinhinKit

/// `telemetry.headers_keychain`: the collector token comes from the token store, becomes a bearer header unless the
/// environment already sets `authorization`, and a failed read costs the header and one warning, never the value.
final class TelemetryHeaderKeychainTests: XCTestCase {
    private let host = TelemetryHostInfo(hostName: "h", architecture: "arm64", osVersion: "26.0.0")
    private let secret = "glc_super-secret-collector-token"

    private struct Boom: LocalizedError {
        var errorDescription: String? { "Keychain said no, and the item holds glc_super-secret-collector-token" }
    }

    override func tearDown() {
        LogRedactor.forgetAllSecretsForTesting()
        super.tearDown()
    }

    private func resolve(
        env: [String: String] = [:], account: String? = "grafana",
        read: @escaping (String) throws -> String? = { _ in nil }
    ) -> TelemetrySettings {
        TelemetryResolver.resolve(
            KinhinConfig.TelemetryConfig(enabled: true, headersKeychain: account), environment: env, host: host,
            keychainSecret: read)
    }

    func testStoredTokenIsSentAsABearerHeader() {
        var asked: [String] = []
        let settings = resolve { name in
            asked.append(name)
            return self.secret
        }
        XCTAssertEqual(asked, ["grafana"])
        XCTAssertEqual(settings.headers["Authorization"], "Bearer \(secret)")
        XCTAssertTrue(settings.warnings.isEmpty, "\(settings.warnings)")
    }

    func testTheTokenIsRegisteredWithTheRedactor() {
        _ = resolve { _ in self.secret }
        XCTAssertFalse(LogRedactor.redact("sending \(secret) now").contains(secret))
    }

    func testTheTokenNeverAppearsInTheDescription() {
        let settings = resolve { _ in self.secret }
        XCTAssertFalse(settings.description.contains(secret), settings.description)
        XCTAssertFalse("\(settings)".contains(secret), "\(settings)")
        let status = TelemetryStatus(settings: settings, prometheusPort: 0, startedAt: Date())
        XCTAssertFalse("\(status)".contains(secret))
    }

    func testEnvironmentAuthorizationWinsAndTheKeychainIsNotRead() {
        for header in ["authorization=Bearer from-env", "Authorization=Basic abc"] {
            var read = false
            let settings = resolve(env: ["OTEL_EXPORTER_OTLP_HEADERS": header]) { _ in
                read = true
                return self.secret
            }
            XCTAssertFalse(read, "\(header): no Keychain read when the environment sets authorization")
            XCTAssertEqual(settings.headers.count, 1)
            XCTAssertFalse(settings.headers.values.contains { $0.contains(self.secret) })
        }
    }

    func testOtherEnvironmentHeadersAreKept() {
        let settings = resolve(env: ["OTEL_EXPORTER_OTLP_HEADERS": "x-scope-orgid=team-a"]) { _ in self.secret }
        XCTAssertEqual(settings.headers["x-scope-orgid"], "team-a")
        XCTAssertEqual(settings.headers["Authorization"], "Bearer \(secret)")
    }

    func testMissingItemStartsWithoutTheHeaderAndWarnsOnceNamingTheAccount() {
        let settings = resolve { _ in nil }
        XCTAssertTrue(settings.enabled)
        XCTAssertNil(settings.headers["Authorization"])
        XCTAssertEqual(settings.warnings.count, 1)
        XCTAssertTrue(settings.warnings[0].contains("'grafana'"), settings.warnings[0])
    }

    func testUnreadableKeychainStartsWithoutTheHeaderAndNeverEchoesTheError() {
        LogRedactor.registerSecret(secret)
        let settings = resolve { _ in throw Boom() }
        XCTAssertTrue(settings.enabled)
        XCTAssertNil(settings.headers["Authorization"])
        XCTAssertEqual(settings.warnings.count, 1)
        XCTAssertTrue(settings.warnings[0].contains("'grafana'"))
        XCTAssertFalse(settings.warnings[0].contains(secret), "the error text is not repeated")
    }

    func testNoKeyMeansNoKeychainRead() {
        var read = false
        _ = resolve(account: nil) { _ in
            read = true
            return self.secret
        }
        XCTAssertFalse(read)
    }

    func testTelemetryOffReadsNothing() {
        var read = false
        let settings = TelemetryResolver.resolve(
            KinhinConfig.TelemetryConfig(enabled: false, headersKeychain: "grafana"), environment: [:], host: host,
            keychainSecret: { _ in
                read = true
                return self.secret
            })
        XCTAssertEqual(settings, .disabled)
        XCTAssertFalse(read)
    }

    func testAChangedTokenCountsAsChangedSettings() {
        XCTAssertNotEqual(resolve { _ in "one" }, resolve { _ in "two" }, "a reload with a rotated token restarts")
    }

    #if DEBUG
        // The token store half: the environment source stands in for the Keychain here.
        func testTokenStoreReadsTheEnvironmentSourceUnderTheTelemetryName() throws {
            KeychainTokenStore.resetEnvironmentModeForTesting()
            defer { KeychainTokenStore.resetEnvironmentModeForTesting() }
            let value = secret
            KeychainTokenStore.environmentProvider = {
                ["KINHIN_TOKEN_STORE": "env", "KINHIN_TOKEN_TELEMETRY_GRAFANA": value]
            }
            XCTAssertEqual(try KeychainTokenStore.loadTelemetryToken(account: "grafana"), secret)
            XCTAssertNil(try KeychainTokenStore.loadTelemetryToken(account: "other"))
            XCTAssertEqual(KeychainTokenStore.telemetryAccount("grafana"), "telemetry:grafana")
        }

        func testTokenStoreSavesForTheSessionInEnvironmentMode() throws {
            KeychainTokenStore.resetEnvironmentModeForTesting()
            defer { KeychainTokenStore.resetEnvironmentModeForTesting() }
            KeychainTokenStore.environmentProvider = { ["KINHIN_TOKEN_STORE": "env"] }
            try KeychainTokenStore.saveTelemetryToken("saved-token-value", account: "grafana")
            XCTAssertEqual(try KeychainTokenStore.loadTelemetryToken(account: "grafana"), "saved-token-value")
        }
    #endif
}
