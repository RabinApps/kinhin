import Foundation

/// The CLI's entry to alert delivery: a one-off test message through the configured webhook.
public enum AlertDelivery {
    /// Sends a synthetic `test` alert to the webhook of `alerts` and returns the line to show. Works while
    /// `alerts.enabled` is still false, so a setup can be checked before it is switched on. Throws
    /// `AlertError` when the webhook is not configured, its Keychain token is missing, or the endpoint rejects it.
    public static func sendTest(_ alerts: KinhinConfig.AlertsConfig, now: Date = Date()) async throws -> String {
        guard alerts.webhookURL != nil else { throw AlertError.notConfigured }
        let sink = try FleetEngine.makeAlertSink(alerts)
        let event = AlertEvent(
            source: "test", severity: .warning, state: .firing, message: "test alert from kinhin",
            host: ProcessInfo.processInfo.hostName, timestamp: now)
        try await sink.send(event)
        return "test alert sent to \(redactedEndpoint(sink.url))"
    }

    /// `scheme://host` only: the path of a webhook URL is often its secret (Slack, Discord, ntfy topics).
    static func redactedEndpoint(_ url: URL) -> String {
        "\(url.scheme ?? "https")://\(url.host ?? "?")"
    }
}
