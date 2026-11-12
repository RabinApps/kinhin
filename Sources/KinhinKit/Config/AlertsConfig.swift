import Foundation

extension KinhinConfig {
    /// Outbound alerts (`alerts:`): the daemon POSTs a message to a webhook when a problem is raised or clears,
    /// so a closed menu bar app or a headless host still reaches you. Off by default; while `enabled` is false
    /// kinhin sends nothing.
    public struct AlertsConfig: Sendable, Equatable {
        /// The body shape the receiving service expects.
        public enum Format: String, Sendable, CaseIterable {
            /// The `AlertEvent` as JSON.
            case generic
            case slack, discord, ntfy
        }

        public var enabled: Bool
        /// The webhook endpoint. https only, except for this Mac.
        public var webhookURL: String?
        public var format: Format
        /// Name of a Keychain item holding a bearer token for the endpoint, sent as `Authorization: Bearer <token>`.
        /// The token itself is never in the config file.
        public var headersKeychain: String?
        public var minSeverity: AlertSeverity
        /// How long a still-raised problem stays quiet before it is sent again.
        public var cooldownSeconds: Int
        public var notifyOnResolve: Bool

        public init(
            enabled: Bool = false, webhookURL: String? = nil, format: Format = .generic,
            headersKeychain: String? = nil, minSeverity: AlertSeverity = .warning, cooldownSeconds: Int = 3_600,
            notifyOnResolve: Bool = true
        ) {
            self.enabled = enabled
            self.webhookURL = webhookURL
            self.format = format
            self.headersKeychain = headersKeychain
            self.minSeverity = minSeverity
            self.cooldownSeconds = cooldownSeconds
            self.notifyOnResolve = notifyOnResolve
        }

        public static let `default` = AlertsConfig()

        /// The allowed range of `cooldown_seconds`.
        static let cooldownRange = 60...86_400
    }
}
