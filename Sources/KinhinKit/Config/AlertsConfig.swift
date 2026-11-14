import Foundation

/// What kind of problem an alert reports: the fixed catalog a webhook's `events:` list picks from. Each raising
/// subsystem (`AlertEvent.source`) maps to exactly one kind.
public enum AlertEventKind: String, Sendable, CaseIterable, Codable, Comparable {
    case disk, credentials, queue
    case spawnBackoff = "spawn-backoff"
    case orphans, startup
    /// The synthetic message of `kinhin alerts test`.
    case test

    public static func < (lhs: AlertEventKind, rhs: AlertEventKind) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }

    /// The kinds a webhook can pick: everything but the synthetic `test`.
    public static let selectable = allCases.filter { $0 != .test }

    /// The kind of an alert source (`"queue:<account>"` is `queue`), or nil for a source outside the catalog
    /// (the healing and agent alerts), which only a webhook with no `events:` filter receives.
    public static func of(source: String) -> AlertEventKind? {
        let base = source.split(separator: ":", maxSplits: 1).first.map(String.init) ?? source
        return AlertEventKind(rawValue: base)
    }
}

extension KinhinConfig {
    /// Outbound alerts (`alerts:`): the daemon POSTs a message to each webhook when a problem is raised or clears,
    /// so a closed menu bar app or a headless host still reaches you. Off by default; while `enabled` is false
    /// kinhin sends nothing.
    public struct AlertsConfig: Sendable, Equatable {
        /// The body shape the receiving service expects.
        public enum Format: String, Sendable, CaseIterable {
            /// The `AlertEvent` as JSON.
            case generic
            case slack, discord, ntfy
        }

        /// One destination. Unset policy fields inherit the `alerts:` defaults.
        public struct Webhook: Sendable, Equatable, Identifiable {
            /// Unique among the webhooks; shown in `kinhin alerts test --webhook NAME` and the doctor.
            public var name: String
            /// https only, except for this Mac.
            public var url: String
            public var format: Format
            /// Name of a Keychain item holding a bearer token for the endpoint, sent as `Authorization: Bearer <token>`.
            /// The token itself is never in the config file.
            public var headersKeychain: String?
            /// Overrides `alerts.min_severity` for this webhook.
            public var minSeverity: AlertSeverity?
            /// The kinds this webhook receives; nil = all of them.
            public var events: Set<AlertEventKind>?
            /// Overrides `alerts.notify_on_resolve` for this webhook.
            public var notifyOnResolve: Bool?

            public var id: String { name }

            public init(
                name: String = Webhook.legacyName, url: String, format: Format = .generic,
                headersKeychain: String? = nil, minSeverity: AlertSeverity? = nil,
                events: Set<AlertEventKind>? = nil, notifyOnResolve: Bool? = nil
            ) {
                self.name = name
                self.url = url
                self.format = format
                self.headersKeychain = headersKeychain
                self.minSeverity = minSeverity
                self.events = events
                self.notifyOnResolve = notifyOnResolve
            }

            /// The name given to the single `webhook:` of a config written before `webhooks:` existed.
            public static let legacyName = "default"

            /// Whether this webhook wants `event`: its kind is selected and its severity reaches the minimum.
            func accepts(_ event: AlertEvent, defaultMinSeverity: AlertSeverity) -> Bool {
                if let events {
                    guard let kind = AlertEventKind.of(source: event.source), events.contains(kind) else {
                        return false
                    }
                }
                return event.severity >= (minSeverity ?? defaultMinSeverity)
            }
        }

        public var enabled: Bool
        public var webhooks: [Webhook]
        /// The default minimum severity of a webhook.
        public var minSeverity: AlertSeverity
        /// How long a still-raised problem stays quiet before it is sent again.
        public var cooldownSeconds: Int
        /// The default for a webhook's `notify_on_resolve`.
        public var notifyOnResolve: Bool

        public init(
            enabled: Bool = false, webhooks: [Webhook] = [], minSeverity: AlertSeverity = .warning,
            cooldownSeconds: Int = 3_600, notifyOnResolve: Bool = true
        ) {
            self.enabled = enabled
            self.webhooks = webhooks
            self.minSeverity = minSeverity
            self.cooldownSeconds = cooldownSeconds
            self.notifyOnResolve = notifyOnResolve
        }

        public static let `default` = AlertsConfig()

        /// The allowed range of `cooldown_seconds`.
        static let cooldownRange = 60...86_400

        /// The webhook called `name`, or nil.
        public func webhook(named name: String) -> Webhook? { webhooks.first { $0.name == name } }

        /// The effective notify-on-resolve of `webhook`.
        func resolves(_ webhook: Webhook) -> Bool { webhook.notifyOnResolve ?? notifyOnResolve }
    }
}
