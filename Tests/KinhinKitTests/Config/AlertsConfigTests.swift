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
              webhooks:
                - name: ops
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
                enabled: true,
                webhooks: [
                    .init(name: "ops", url: "https://ntfy.sh/kinhin", format: .ntfy, headersKeychain: "ops-token")
                ], minSeverity: .critical, cooldownSeconds: 900, notifyOnResolve: false))
    }

    func testLegacySingleWebhookBecomesOneNamedDefault() throws {
        let config = try parse(
            """
              enabled: true
              webhook:
                url: https://ntfy.sh/kinhin
                format: ntfy
            """)
        XCTAssertEqual(config.alerts.webhooks, [.init(name: "default", url: "https://ntfy.sh/kinhin", format: .ntfy)])
    }

    func testPerWebhookPolicyAndEvents() throws {
        let config = try parse(
            """
              enabled: true
              notify_on_resolve: true
              webhooks:
                - name: slack
                  url: https://hooks.slack.com/services/x
                  format: slack
                  min_severity: critical
                  events: [disk, spawn-backoff, queue]
                  notify_on_resolve: false
                - name: all
                  url: https://ntfy.sh/all
            """)
        let slack = try XCTUnwrap(config.alerts.webhook(named: "slack"))
        XCTAssertEqual(slack.events, [.disk, .spawnBackoff, .queue])
        XCTAssertEqual(slack.minSeverity, .critical)
        XCTAssertEqual(slack.notifyOnResolve, false)
        XCTAssertNil(config.alerts.webhook(named: "all")?.events)
    }

    func testEventKindsCoverEverySource() {
        XCTAssertEqual(AlertEventKind.of(source: "queue:github"), .queue)
        XCTAssertEqual(AlertEventKind.of(source: "spawn-backoff"), .spawnBackoff)
        XCTAssertEqual(AlertEventKind.of(source: "disk"), .disk)
        XCTAssertNil(AlertEventKind.of(source: "healing"))
    }

    func testWebhookFiltering() {
        let disk = AlertEvent(
            source: "disk", severity: .critical, state: .firing, message: "m", host: "h", timestamp: Date())
        let orphans = AlertEvent(
            source: "orphans", severity: .warning, state: .firing, message: "m", host: "h", timestamp: Date())
        let healing = AlertEvent(
            source: "healing", severity: .critical, state: .firing, message: "m", host: "h", timestamp: Date())
        let all = KinhinConfig.AlertsConfig.Webhook(name: "a", url: "https://x.example.com")
        XCTAssertTrue(all.accepts(healing, defaultMinSeverity: .warning), "no filter = everything")
        let diskOnly = KinhinConfig.AlertsConfig.Webhook(name: "b", url: "https://x.example.com", events: [.disk])
        XCTAssertTrue(diskOnly.accepts(disk, defaultMinSeverity: .warning))
        XCTAssertFalse(diskOnly.accepts(orphans, defaultMinSeverity: .warning))
        XCTAssertFalse(diskOnly.accepts(healing, defaultMinSeverity: .warning))
        let strict = KinhinConfig.AlertsConfig.Webhook(name: "c", url: "https://x.example.com", minSeverity: .critical)
        XCTAssertFalse(strict.accepts(orphans, defaultMinSeverity: .warning))
        XCTAssertFalse(all.accepts(orphans, defaultMinSeverity: .critical))
    }

    func testRejections() {
        XCTAssertThrowsError(try parse("  enabled: true"))
        XCTAssertThrowsError(try parse("  webhook:\n    url: http://example.com/x"))
        XCTAssertThrowsError(try parse("  webhook:\n    url: https://a.example.com\n    format: pager"))
        XCTAssertThrowsError(
            try parse("  webhooks:\n    - name: a\n      url: https://a.example.com\n      events: [bogus]"))
        XCTAssertThrowsError(
            try parse("  webhooks:\n    - name: a\n      url: https://a.example.com\n      events: []"))
        XCTAssertThrowsError(
            try parse(
                "  webhooks:\n    - name: a\n      url: https://a.example.com\n    - name: a\n      url: https://b.example.com"
            ), "duplicate names")
        XCTAssertThrowsError(try parse("  webhooks:\n    - url: https://a.example.com"), "name is required")
        XCTAssertThrowsError(try parse("  webhooks:\n    - name: a"), "url is required")
        XCTAssertThrowsError(
            try parse(
                "  webhook:\n    url: https://a.example.com\n  webhooks:\n    - name: a\n      url: https://b.example.com"
            ), "both forms")
        XCTAssertThrowsError(try parse("  min_severity: loud"))
        XCTAssertThrowsError(try parse("  cooldown_seconds: 5"))
        XCTAssertThrowsError(try parse("  webhook:\n    headers_keychain: \"bad name!\""))
        XCTAssertThrowsError(try parse("  bogus: 1"))
    }
}
