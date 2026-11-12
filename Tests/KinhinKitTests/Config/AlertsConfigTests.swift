import XCTest

@testable import KinhinKit

final class AlertsConfigTests: XCTestCase {
    private func parse(_ alerts: String) throws -> KinhinConfig {
        try ConfigLoader.parse(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/ios-app"
            alerts:
            \(alerts)
            """)
    }

    func testDefaultsAreOff() throws {
        let config = try ConfigLoader.parse("labels: [self-hosted]")
        XCTAssertEqual(config.alerts, .default)
        XCTAssertFalse(config.alerts.enabled)
    }

    func testFullBlock() throws {
        let config = try parse(
            """
              enabled: true
              webhook:
                url: https://ntfy.sh/kinhin
                format: ntfy
                headers_keychain: ops-token
              min_severity: critical
              cooldown_seconds: 900
              notify_on_resolve: false
            """)
        XCTAssertEqual(
            config.alerts,
            .init(
                enabled: true, webhookURL: "https://ntfy.sh/kinhin", format: .ntfy, headersKeychain: "ops-token",
                minSeverity: .critical, cooldownSeconds: 900, notifyOnResolve: false))
    }

    func testRejections() {
        XCTAssertThrowsError(try parse("  enabled: true"))
        XCTAssertThrowsError(try parse("  webhook:\n    url: http://example.com/x"))
        XCTAssertThrowsError(try parse("  webhook:\n    format: pager"))
        XCTAssertThrowsError(try parse("  min_severity: loud"))
        XCTAssertThrowsError(try parse("  cooldown_seconds: 5"))
        XCTAssertThrowsError(try parse("  webhook:\n    headers_keychain: \"bad name!\""))
        XCTAssertThrowsError(try parse("  bogus: 1"))
    }
}
