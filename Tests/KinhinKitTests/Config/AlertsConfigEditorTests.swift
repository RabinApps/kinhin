import XCTest

@testable import KinhinKit

/// The app's Alerts card edits `alerts:` through this: `enabled` is one line, a webhook change rewrites only the
/// `webhooks:` list, everything else survives, and an edit that would not validate is never written.
final class AlertsConfigEditorTests: XCTestCase {
    private let base = """
        # kinhin configuration
        accounts:
          - name: github
            forge: github
            scope: "acme/ios-app"

        labels: ["self-hosted", "macos"]
        """

    private let withAlerts = """
        # kinhin configuration
        accounts:
          - name: github
            forge: github
            scope: "acme/ios-app"

        alerts:
          enabled: true   # keep me
          webhooks:
            - name: ops
              url: https://hooks.example.com/ops
              format: slack
          cooldown_seconds: 900

        labels: ["self-hosted", "macos"]
        """

    private func edit(_ field: AlertsConfigEditor.Field, _ yaml: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-alerts-\(UUID()).yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let text = try AlertsConfigEditor.apply(field, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        return text
    }

    private func webhook(
        _ name: String, events: Set<AlertEventKind>? = nil, keychain: String? = nil
    ) -> KinhinConfig.AlertsConfig.Webhook {
        .init(name: name, url: "https://\(name).example.com/hook", headersKeychain: keychain, events: events)
    }

    func testNoSectionReadsAsOffWithNoWebhooks() throws {
        XCTAssertEqual(try AlertsConfigEditor.snapshot(in: base), .init(enabled: false, webhooks: []))
        XCTAssertEqual(try AlertsConfigEditor.snapshot(in: "\n"), .init(enabled: false, webhooks: []))
    }

    func testSnapshotReadsTheListAndTheLegacyForm() throws {
        let snapshot = try AlertsConfigEditor.snapshot(in: withAlerts)
        XCTAssertTrue(snapshot.enabled)
        XCTAssertEqual(snapshot.webhooks.map(\.name), ["ops"])
        let legacy = try AlertsConfigEditor.snapshot(
            in: base + "\nalerts:\n  webhook:\n    url: https://ntfy.sh/x\n    format: ntfy\n")
        XCTAssertEqual(legacy.webhooks.map(\.name), ["default"])
        XCTAssertEqual(legacy.webhooks.first?.format, .ntfy)
    }

    func testAddingAWebhookCreatesTheSection() throws {
        let text = try edit(.saveWebhook(webhook("ops", events: [.disk, .queue]), replacing: nil), base)
        XCTAssertTrue(text.hasPrefix(base))
        let snapshot = try AlertsConfigEditor.snapshot(in: text)
        XCTAssertFalse(snapshot.enabled)
        XCTAssertEqual(snapshot.webhooks.first?.events, [.disk, .queue])
    }

    func testEnablingNeedsAWebhook() throws {
        XCTAssertThrowsError(try edit(.enabled(true), base))
        let text = try edit(
            .enabled(true), base + "\nalerts:\n  webhooks:\n    - name: a\n      url: https://a.example.com\n")
        XCTAssertTrue(try AlertsConfigEditor.snapshot(in: text).enabled)
    }

    func testDisablingWithoutASectionChangesNothing() throws {
        XCTAssertEqual(try edit(.enabled(false), base), base)
    }

    func testEnabledEditKeepsTheTrailingComment() throws {
        let text = try edit(.enabled(false), withAlerts)
        XCTAssertTrue(text.contains("enabled: false"), text)
        XCTAssertTrue(text.contains("# keep me"), text)
    }

    func testAddingASecondWebhookKeepsTheFirstAndOtherKeys() throws {
        let text = try edit(.saveWebhook(webhook("backup", keychain: "backup"), replacing: nil), withAlerts)
        XCTAssertEqual(try AlertsConfigEditor.snapshot(in: text).webhooks.map(\.name), ["ops", "backup"])
        XCTAssertTrue(text.contains("cooldown_seconds: 900"))
        XCTAssertTrue(text.contains("labels: [\"self-hosted\", \"macos\"]"))
        XCTAssertTrue(text.contains("# keep me"))
    }

    func testReplacingRenamesAndKeepsPosition() throws {
        let text = try edit(.saveWebhook(webhook("renamed", events: [.startup]), replacing: "ops"), withAlerts)
        let snapshot = try AlertsConfigEditor.snapshot(in: text)
        XCTAssertEqual(snapshot.webhooks.map(\.name), ["renamed"])
        XCTAssertEqual(snapshot.webhooks.first?.events, [.startup])
    }

    func testRemovingTheLastWebhookWhileEnabledIsRefused() throws {
        XCTAssertThrowsError(try edit(.removeWebhook("ops"), withAlerts))
        let off = withAlerts.replacingOccurrences(of: "enabled: true", with: "enabled: false")
        let text = try edit(.removeWebhook("ops"), off)
        XCTAssertTrue(try AlertsConfigEditor.snapshot(in: text).webhooks.isEmpty)
        XCTAssertTrue(text.contains("cooldown_seconds: 900"))
    }

    func testDuplicateNameIsRefusedAndNothingIsWritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-alerts-\(UUID()).yaml")
        try withAlerts.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try AlertsConfigEditor.apply(.saveWebhook(webhook("ops"), replacing: nil), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), withAlerts)
    }

    func testLegacyWebhookIsFoldedIntoTheList() throws {
        let legacy =
            base
            + "\nalerts:\n  enabled: true\n  webhook:\n    url: https://ntfy.sh/x\n    format: ntfy\n  min_severity: critical\n"
        let text = try edit(.saveWebhook(webhook("second"), replacing: nil), legacy)
        XCTAssertFalse(text.contains("  webhook:"))
        XCTAssertEqual(try AlertsConfigEditor.snapshot(in: text).webhooks.map(\.name), ["default", "second"])
        XCTAssertTrue(text.contains("min_severity: critical"))
    }

    func testFlowStyleSectionIsRefusedWithAnExplanation() {
        XCTAssertThrowsError(try AlertsConfigEditor.replace(.enabled(true), in: base + "\nalerts: {enabled: false}\n"))
        {
            XCTAssertTrue($0.localizedDescription.contains("block style"))
        }
    }
}
