import E2ESupport
import Foundation
import Testing

/// Outbound alerts (`alerts:`, docs/alerts.md), against the real `kinhin` binary and a real `kinhin daemon`. Quick tier,
/// no Docker: the forge is unreachable on purpose (as in `SecurityTests`), so the fleet cannot start and the daemon sends
/// its one `startup` alert. The webhook is `WebhookStub`, a local listener that records every POST; nothing leaves the Mac.
/// A raised-then-cleared problem needs a fleet that starts, so that pair is covered by the unit suite, and a real
/// Slack/Discord/ntfy endpoint is still a manual check.
@Suite("Alerts", .serialized, .tags(.cli), .enabled(if: E2E.enabled))
struct AlertsTests {
    private static let account = """
        version: 1
        accounts:
          - name: gitea
            forge: gitea
            scope: acme/widgets
            instance: http://127.0.0.1:9

        """

    private static func alerts(_ url: String, format: String) -> String {
        account
            + "alerts:\n  enabled: true\n  webhooks:\n    - name: hook\n      url: \(url)\n      format: \(format)\n"
    }

    private func withSandbox<T>(_ body: (Sandbox) async throws -> T) async throws -> T {
        let sandbox = try Sandbox()
        defer { sandbox.dispose() }
        sandbox.setToken("unreachable-forge-token", account: "gitea")
        return try await body(sandbox)
    }

    @Test(
        "a fleet that cannot start sends one startup alert in the configured format",
        arguments: ["generic", "slack", "discord", "ntfy"])
    func startupAlert(format: String) async throws {
        let hook = try await WebhookStub()
        defer { hook.stop() }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.alerts(hook.url, format: format))
            let validated = try await sandbox.kinhin(["config", "validate"])
            #expect(validated.ok, "alerts: must validate: \(validated.output)")
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }

            let posts = try await eventually("the startup alert", timeout: 45, interval: 1) {
                let posts = await hook.requests()
                return posts.isEmpty ? nil : posts
            }
            let post = try #require(posts.first)
            #expect(post.path == "/hook")
            switch format {
            case "generic":
                #expect(post.headers["content-type"]?.hasPrefix("application/json") == true)
                let json = try #require(post.json, "generic body is a JSON object: \(post.body)")
                #expect(json["source"] as? String == "startup")
                #expect(json["state"] as? String == "firing")
                #expect(json["severity"] as? String == "critical")
                #expect(json["host"] is String && json["timestamp"] is String && json["message"] is String)
            case "slack":
                #expect(post.headers["content-type"]?.hasPrefix("application/json") == true)
                #expect((post.json?["text"] as? String)?.contains("startup") == true, "\(post.body)")
            case "discord":
                #expect(post.headers["content-type"]?.hasPrefix("application/json") == true)
                #expect((post.json?["content"] as? String)?.contains("startup") == true, "\(post.body)")
            default:  // ntfy: the message is the plain-text body, with a title header
                #expect(post.headers["content-type"]?.hasPrefix("text/plain") == true)
                #expect(post.headers["title"] == "kinhin")
                #expect(post.body.contains("startup"), "\(post.body)")
            }
            #expect(!post.body.contains("unreachable-forge-token"), "the token never reaches the webhook")

            // Sent once: the alert loop only runs for a started fleet, so nothing follows.
            try await Task.sleep(for: .seconds(5))
            #expect(await hook.requests().count == 1, "one startup alert, not a stream")
        }
    }

    @Test("with no alerts: section, or enabled: false, the webhook receives nothing")
    func offByDefault() async throws {
        let hook = try await WebhookStub()
        defer { hook.stop() }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.account)
            let daemon = try await sandbox.startDaemon()
            try await Task.sleep(for: .seconds(8))
            await daemon.stop()
            #expect(await hook.requests().isEmpty, "no alerts: section sends nothing")
        }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                Self.account + "alerts:\n  enabled: false\n  webhooks:\n    - name: hook\n      url: \(hook.url)\n")
            let daemon = try await sandbox.startDaemon()
            try await Task.sleep(for: .seconds(8))
            await daemon.stop()
            #expect(await hook.requests().isEmpty, "enabled: false sends nothing")
        }
    }

    @Test("a dead endpoint is logged and never stops the daemon")
    func deadEndpoint() async throws {
        let hook = try await WebhookStub(status: 500)
        defer { hook.stop() }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.alerts(hook.url, format: "generic"))
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            try await eventually("the failing endpoint to be tried", timeout: 45, interval: 1) {
                await hook.requests().isEmpty ? nil : true
            }
            let status = try await sandbox.kinhin(["status", "--json"], timeout: 15)
            #expect(status.ok, "the daemon still answers: \(status.output)")
        }
    }

    @Test("alerts test posts one message, exits 4 on a refusing endpoint and 3 with no url")
    func alertsTestCommand() async throws {
        let hook = try await WebhookStub()
        let refusing = try await WebhookStub(status: 500)
        defer {
            hook.stop()
            refusing.stop()
        }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.alerts(hook.url, format: "slack"))
            let sent = try await sandbox.kinhin(["alerts", "test"])
            #expect(sent.ok, "\(sent.output)")
            #expect(!sent.output.contains("/hook"), "only scheme://host is printed: \(sent.output)")
            #expect(await hook.requests().count == 1)

            try sandbox.writeConfig(Self.alerts(refusing.url, format: "generic"))
            let refused = try await sandbox.kinhin(["alerts", "test"])
            #expect(refused.status == 4, "a refusing endpoint exits 4: \(refused.output)")

            try sandbox.writeConfig(Self.account)
            let unset = try await sandbox.kinhin(["alerts", "test"])
            #expect(unset.status == 3, "no webhook exits 3: \(unset.output)")
        }
    }

    @Test("two webhooks with different events each receive only their own event types")
    func perWebhookEvents() async throws {
        let wanted = try await WebhookStub()
        let unwanted = try await WebhookStub()
        let everything = try await WebhookStub()
        defer {
            wanted.stop()
            unwanted.stop()
            everything.stop()
        }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                Self.account
                    + """
                    alerts:
                      enabled: true
                      webhooks:
                        - name: startup-only
                          url: \(wanted.url)
                          events: [startup]
                        - name: disk-only
                          url: \(unwanted.url)
                          events: [disk]
                        - name: everything
                          url: \(everything.url)
                          format: slack

                    """)
            let validated = try await sandbox.kinhin(["config", "validate"])
            #expect(validated.ok, "\(validated.output)")
            let daemon = try await sandbox.startDaemon()
            defer { Task { await daemon.stop() } }
            let first = try await eventually("the startup alerts", timeout: 45, interval: 1) {
                let count = await wanted.requests().count + (await everything.requests().count)
                return count >= 2 ? true : nil
            }
            #expect(first)
            try await Task.sleep(for: .seconds(5))
            #expect(await wanted.requests().count == 1, "startup-only gets the startup alert")
            #expect(await everything.requests().count == 1, "no events: filter gets it too")
            #expect(await unwanted.requests().isEmpty, "disk-only never sees a startup alert")
        }
    }

    @Test("alerts test --webhook reaches only that webhook; an unknown name exits 3")
    func alertsTestOneWebhook() async throws {
        let first = try await WebhookStub()
        let second = try await WebhookStub()
        defer {
            first.stop()
            second.stop()
        }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(
                Self.account
                    + "alerts:\n  webhooks:\n    - name: one\n      url: \(first.url)\n      events: [disk]\n"
                    + "    - name: two\n      url: \(second.url)\n")
            let sent = try await sandbox.kinhin(["alerts", "test", "--webhook", "two"])
            #expect(sent.ok, "\(sent.output)")
            #expect(await first.requests().isEmpty)
            #expect(await second.requests().count == 1)
            let both = try await sandbox.kinhin(["alerts", "test"])
            #expect(both.ok, "a test ignores the events filter: \(both.output)")
            #expect(await first.requests().count == 1)
            let unknown = try await sandbox.kinhin(["alerts", "test", "--webhook", "nope"])
            #expect(unknown.status == 3, "\(unknown.output)")
        }
    }

    @Test("the old single webhook: form still validates and tests as one webhook named default")
    func legacyWebhook() async throws {
        let hook = try await WebhookStub()
        defer { hook.stop() }
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.account + "alerts:\n  enabled: true\n  webhook:\n    url: \(hook.url)\n")
            let validated = try await sandbox.kinhin(["config", "validate"])
            #expect(validated.ok, "\(validated.output)")
            let sent = try await sandbox.kinhin(["alerts", "test", "--webhook", "default"])
            #expect(sent.ok, "\(sent.output)")
            #expect(await hook.requests().count == 1)
        }
    }

    @Test("a plain-http webhook is refused unless it is loopback")
    func httpPolicy() async throws {
        try await withSandbox { sandbox in
            try sandbox.writeConfig(Self.alerts("http://example.com/hook", format: "generic"))
            let result = try await sandbox.kinhin(["config", "validate"])
            #expect(!result.ok && result.status == 3, "non-loopback http exits 3: \(result.output)")
        }
    }
}
