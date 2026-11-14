import Foundation

/// The CLI's entry to alert delivery: a one-off test message through the configured webhooks.
public enum AlertDelivery {
    /// Sends a synthetic `test` alert to the webhooks of `alerts` (only `name` when given) and returns one line per
    /// webhook. Works while `alerts.enabled` is still false, so a setup can be checked before it is switched on. The
    /// webhook's event filter is bypassed: a test checks the endpoint, not the routing. Throws `AlertError` when no
    /// webhook is configured or `name` is unknown, and the first delivery failure (a missing Keychain token, an
    /// endpoint that rejects it) after every webhook was tried.
    public static func sendTest(
        _ alerts: KinhinConfig.AlertsConfig, webhook name: String? = nil, now: Date = Date()
    ) async throws -> [String] {
        try await sendTest(
            alerts, webhook: name, now: now, http: URLSessionAlertHTTP(),
            token: { try KeychainTokenStore.loadAlertsToken(account: $0) })
    }

    static func sendTest(
        _ alerts: KinhinConfig.AlertsConfig, webhook name: String?, now: Date, http: any AlertHTTP,
        token: (String) throws -> String?
    ) async throws -> [String] {
        let targets: [KinhinConfig.AlertsConfig.Webhook]
        if let name {
            guard let found = alerts.webhook(named: name) else { throw AlertError.unknownWebhook(name) }
            targets = [found]
        } else {
            targets = alerts.webhooks
        }
        guard !targets.isEmpty else { throw AlertError.notConfigured }
        let event = AlertEvent(
            source: "test", severity: .warning, state: .firing, message: "test alert from kinhin",
            host: ProcessInfo.processInfo.hostName, timestamp: now)
        var lines: [String] = []
        var firstFailure: Error?
        for webhook in targets {
            do {
                let sink = try FleetEngine.makeAlertSink(webhook, http: http, token: token)
                try await sink.send(event)
                lines.append("test alert sent to \(webhook.name) (\(redactedEndpoint(sink.url)))")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lines.append("\(webhook.name): \(error.localizedDescription)")
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw AlertDeliveryFailure(lines: lines, cause: firstFailure) }
        return lines
    }

    /// `scheme://host` only: the path of a webhook URL is often its secret (Slack, Discord, ntfy topics).
    public static func redactedEndpoint(_ url: URL) -> String {
        "\(url.scheme ?? "https")://\(url.host ?? "?")"
    }
}

/// A test that reached some webhooks and not others: `lines` holds the outcome of every one.
public struct AlertDeliveryFailure: LocalizedError {
    public let lines: [String]
    public let cause: Error
    public var errorDescription: String? { lines.joined(separator: "\n") }
}
