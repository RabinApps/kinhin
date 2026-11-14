import Foundation

// MARK: - Alerts

extension ConfigLoader {
    /// `alerts:`: every key optional, defaults from `AlertsConfig` (off). Enabling needs a webhook URL.
    static func parseAlerts(_ partial: PartialConfig.PartialAlerts) throws -> KinhinConfig.AlertsConfig {
        typealias Alerts = KinhinConfig.AlertsConfig
        var alerts = Alerts.default
        if let enabled = partial.enabled { alerts.enabled = enabled }
        if partial.webhook != nil, partial.webhooks != nil {
            throw ConfigError.invalid("alerts.webhook and alerts.webhooks are both set; use alerts.webhooks only")
        }
        if let legacy = partial.webhook {
            var entry = legacy
            entry.name = Alerts.Webhook.legacyName
            // The old form allowed a missing url while alerts were off; its other keys are still checked, and it
            // is simply no webhook.
            let hasURL = entry.url != nil
            if !hasURL { entry.url = "https://placeholder.invalid" }
            let webhook = try parseWebhook(entry, key: "alerts.webhook")
            if hasURL { alerts.webhooks = [webhook] }
        }
        if let list = partial.webhooks {
            var seen: Set<String> = []
            for (index, raw) in list.enumerated() {
                let webhook = try parseWebhook(raw, key: "alerts.webhooks[\(index)]")
                guard seen.insert(webhook.name).inserted else {
                    throw ConfigError.invalid("alerts.webhooks[\(index)].name '\(webhook.name)' is used twice")
                }
                alerts.webhooks.append(webhook)
            }
        }
        if let raw = partial.minSeverity {
            guard let severity = AlertSeverity(rawValue: raw) else {
                throw ConfigError.invalid("alerts.min_severity must be warning or critical, got '\(raw)'")
            }
            alerts.minSeverity = severity
        }
        if let seconds = partial.cooldownSeconds {
            let range = Alerts.cooldownRange
            guard range.contains(seconds) else {
                throw ConfigError.invalid(
                    "alerts.cooldown_seconds must be between \(range.lowerBound) and \(range.upperBound), got \(seconds)"
                )
            }
            alerts.cooldownSeconds = seconds
        }
        if let resolve = partial.notifyOnResolve { alerts.notifyOnResolve = resolve }
        if alerts.enabled, alerts.webhooks.isEmpty {
            throw ConfigError.invalid("alerts.enabled needs at least one entry in alerts.webhooks")
        }
        return alerts
    }

    /// One `alerts.webhooks:` entry. `key` is its path in error messages.
    static func parseWebhook(
        _ partial: PartialConfig.PartialAlerts.PartialWebhook, key: String
    ) throws -> KinhinConfig.AlertsConfig.Webhook {
        typealias Alerts = KinhinConfig.AlertsConfig
        let name = try validateKeychainName(partial.name ?? "", key: "\(key).name")
        guard let raw = partial.url?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            throw ConfigError.invalid("\(key).url is required")
        }
        do {
            _ = try WebhookSink.validate(raw)
        } catch {
            throw ConfigError.invalid("\(key).url must be an https URL (http only for localhost, 127.0.0.1 or ::1)")
        }
        var webhook = Alerts.Webhook(name: name, url: raw)
        if let raw = partial.format {
            guard let format = Alerts.Format(rawValue: raw) else {
                throw ConfigError.invalid("\(key).format must be generic, slack, discord or ntfy, got '\(raw)'")
            }
            webhook.format = format
        }
        if let raw = partial.headersKeychain {
            webhook.headersKeychain = try validateKeychainName(raw, key: "\(key).headers_keychain")
        }
        if let raw = partial.minSeverity {
            guard let severity = AlertSeverity(rawValue: raw) else {
                throw ConfigError.invalid("\(key).min_severity must be warning or critical, got '\(raw)'")
            }
            webhook.minSeverity = severity
        }
        if let raws = partial.events {
            var kinds: Set<AlertEventKind> = []
            for raw in raws {
                guard let kind = AlertEventKind(rawValue: raw) else {
                    let known = AlertEventKind.allCases.map(\.rawValue).joined(separator: ", ")
                    throw ConfigError.invalid("\(key).events has unknown event type '\(raw)'; use \(known)")
                }
                kinds.insert(kind)
            }
            guard !kinds.isEmpty else {
                throw ConfigError.invalid("\(key).events must not be empty; omit it to receive every event type")
            }
            webhook.events = kinds
        }
        webhook.notifyOnResolve = partial.notifyOnResolve
        return webhook
    }

    /// A Keychain account name: letters, digits, '.', '_' or '-', at most `telemetryKeychainNameLimit` characters.
    static func validateKeychainName(_ raw: String, key: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !name.isEmpty, name.count <= telemetryKeychainNameLimit,
            name.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw ConfigError.invalid(
                "\(key) must be a Keychain account name of letters, digits, '.', '_' or '-' "
                    + "(at most \(telemetryKeychainNameLimit) characters), got '\(raw)'")
        }
        return name
    }
}
