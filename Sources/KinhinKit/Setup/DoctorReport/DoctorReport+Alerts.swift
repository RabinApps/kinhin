import Foundation

extension DoctorReport {
    /// The outbound-alerts state (`alerts:`): one entry per webhook, and the first problem among them.
    public struct AlertsSection: Codable, Equatable, Sendable {
        /// One configured webhook.
        public struct Webhook: Codable, Equatable, Sendable {
            public let name: String
            /// `scheme://host` of the webhook: its path is often the secret, so it is never shown.
            public let endpoint: String?
            public let format: String
            /// The event types it receives; nil = all.
            public let events: [String]?
            /// Whether the Keychain token `headers_keychain` names is stored; nil when no token is needed.
            public let tokenStored: Bool?
            public let ok: Bool
            /// What is wrong, null when ok.
            public let problem: String?
            /// The command that fixes it, null when ok.
            public let fix: String?

            public init(
                name: String, endpoint: String?, format: String, events: [String]?, tokenStored: Bool?, ok: Bool,
                problem: String?, fix: String?
            ) {
                self.name = name
                self.endpoint = endpoint
                self.format = format
                self.events = events
                self.tokenStored = tokenStored
                self.ok = ok
                self.problem = problem
                self.fix = fix
            }
        }

        public let enabled: Bool
        public let webhooks: [Webhook]

        public init(enabled: Bool, webhooks: [Webhook]) {
            self.enabled = enabled
            self.webhooks = webhooks
            self.ok = webhooks.allSatisfy(\.ok)
        }

        /// Whether every webhook can deliver.
        public let ok: Bool
    }
}
