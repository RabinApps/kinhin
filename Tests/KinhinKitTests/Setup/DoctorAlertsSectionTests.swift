import XCTest

@testable import KinhinKit

/// The outbound-alerts state `kinhin doctor` reports.
final class DoctorAlertsSectionTests: XCTestCase {
    private let host = HostResources(logicalCores: 10, memoryGB: 32, freeDiskGB: 200, arm64: true)

    private func config(_ alerts: KinhinConfig.AlertsConfig) -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: "acme/widgets")]
        cfg.alerts = alerts
        return cfg
    }

    private func report(_ alerts: KinhinConfig.AlertsConfig, tokenStored: Bool = true) async -> DoctorReport {
        await DoctorReportBuilder(
            host: host, clt: .ok(version: "26.6"), tartHealth: .healthy, tartList: [],
            config: .loaded(config(alerts)), authLoad: { _ in "tok" }, accountLoad: { _, _ in "tok" },
            softnetInstalled: true,
            hostKeyMarker: FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-no-marker-\(UUID())"),
            alertsTokenStored: { _ in tokenStored }
        ).build()
    }

    func testAbsentWhileAlertsAreOff() async {
        let doctor = await report(.default)
        XCTAssertNil(doctor.alerts)
    }

    func testEnabledWithTokenIsOkAndHidesThePath() async throws {
        let alerts = KinhinConfig.AlertsConfig(
            enabled: true,
            webhooks: [.init(name: "ops", url: "https://hooks.example.com/secret/path", headersKeychain: "ops")])
        let doctor = await report(alerts)
        let section = try XCTUnwrap(doctor.alerts)
        XCTAssertTrue(section.ok)
        XCTAssertEqual(section.webhooks.first?.endpoint, "https://hooks.example.com")
        XCTAssertEqual(section.webhooks.first?.tokenStored, true)
        XCTAssertFalse(doctor.plainText.contains("secret/path"))
        XCTAssertTrue(doctor.plainText.contains("alerts"))
    }

    func testMissingTokenFailsTheReportWithTheFix() async throws {
        let alerts = KinhinConfig.AlertsConfig(
            enabled: true, webhooks: [.init(name: "ops", url: "https://hooks.example.com/x", headersKeychain: "ops")])
        let doctor = await report(alerts, tokenStored: false)
        let section = try XCTUnwrap(doctor.alerts)
        XCTAssertFalse(section.ok)
        XCTAssertEqual(section.webhooks.first?.fix, "kinhin alerts set-token ops")
        XCTAssertFalse(doctor.ready)
    }

    func testUnreadableTokenIsReportedAsAReadFailureNotAMissingItem() async throws {
        struct Locked: Error, LocalizedError { var errorDescription: String? { "the Keychain is locked" } }
        let alerts = KinhinConfig.AlertsConfig(
            enabled: true, webhooks: [.init(name: "ops", url: "https://hooks.example.com/x", headersKeychain: "ops")])
        let section = try XCTUnwrap(
            DoctorReportBuilder.alertsSection(config: config(alerts), tokenStored: { _ in throw Locked() }))
        let webhook = try XCTUnwrap(section.webhooks.first)
        XCTAssertFalse(section.ok)
        XCTAssertNil(webhook.fix, "set-token would not help: the item may exist")
        XCTAssertTrue(webhook.problem?.contains("could not be read") == true)
        XCTAssertTrue(webhook.problem?.contains("the Keychain is locked") == true)
    }

    func testNoTokenNeededWithoutAKeychainName() async throws {
        let alerts = KinhinConfig.AlertsConfig(
            enabled: true, webhooks: [.init(name: "ntfy", url: "https://ntfy.sh/topic")])
        let doctor = await report(alerts, tokenStored: false)
        let section = try XCTUnwrap(doctor.alerts)
        XCTAssertTrue(section.ok)
        XCTAssertNil(section.webhooks.first?.tokenStored)
    }

    func testEachWebhookIsReportedAndOneMissingTokenFailsTheSection() async throws {
        let alerts = KinhinConfig.AlertsConfig(
            enabled: true,
            webhooks: [
                .init(name: "a", url: "https://a.example.com/x", events: [.queue, .disk]),
                .init(name: "b", url: "https://b.example.com/x", headersKeychain: "b-token"),
            ])
        let section = try XCTUnwrap(
            DoctorReportBuilder.alertsSection(config: config(alerts), tokenStored: { _ in false }))
        XCTAssertEqual(section.webhooks.map(\.name), ["a", "b"])
        XCTAssertEqual(section.webhooks[0].events, ["disk", "queue"])
        XCTAssertTrue(section.webhooks[0].ok)
        XCTAssertFalse(section.webhooks[1].ok)
        XCTAssertFalse(section.ok)
    }
}
