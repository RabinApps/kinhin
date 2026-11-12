import Foundation

// MARK: - Alerts

extension ConfigLoader {
    /// `alerts:`: every key optional, defaults from `AlertsConfig` (off). Enabling needs a webhook URL.
    static func parseAlerts(_ partial: PartialConfig.PartialAlerts) throws -> KinhinConfig.AlertsConfig {
        typealias Alerts = KinhinConfig.AlertsConfig
        var alerts = Alerts.default
        if let enabled = partial.enabled { alerts.enabled = enabled }
        if let webhook = partial.webhook {
            if let raw = webhook.url {
                let url = raw.trimmingCharacters(in: .whitespaces)
                do {
                    _ = try WebhookSink.validate(url)
                } catch {
                    throw ConfigError.invalid(
                        "alerts.webhook.url must be an https URL (http only for localhost, 127.0.0.1 or ::1), got '\(raw)'"
                    )
                }
                alerts.webhookURL = url
            }
            if let raw = webhook.format {
                guard let format = Alerts.Format(rawValue: raw) else {
                    throw ConfigError.invalid(
                        "alerts.webhook.format must be generic, slack, discord or ntfy, got '\(raw)'")
                }
                alerts.format = format
            }
            if let raw = webhook.headersKeychain {
                alerts.headersKeychain = try validateKeychainName(raw, key: "alerts.webhook.headers_keychain")
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
        if alerts.enabled, alerts.webhookURL == nil {
            throw ConfigError.invalid("alerts.enabled needs alerts.webhook.url")
        }
        return alerts
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
