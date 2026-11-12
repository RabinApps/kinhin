import Foundation

/// Turns successive snapshots of the fleet's active problems into `AlertEvent`s and delivers them.
///
/// A source that appears fires once; while it stays raised it fires again only after `cooldown`; when it
/// clears and a firing was sent, a `resolved` follows (if `notifyOnResolve`). A failing sink is logged and
/// never reported back as a fleet problem, so a dead endpoint cannot raise the alert that it then fails to send.
actor AlertDispatcher {
    struct Policy: Sendable, Equatable {
        var minSeverity: AlertSeverity = .warning
        var cooldown: TimeInterval = 3_600
        var notifyOnResolve = true
    }

    private struct Sent {
        var at: Date
        var severity: AlertSeverity
    }

    private let sinks: [any AlertSink]
    private let policy: Policy
    private let host: String
    private var active: [String: Sent] = [:]

    init(sinks: [any AlertSink], policy: Policy, host: String = ProcessInfo.processInfo.hostName) {
        self.sinks = sinks
        self.policy = policy
        self.host = host
    }

    /// Compares `alerts` (every problem active now) with what was last sent, and delivers the difference.
    func observe(_ alerts: [FleetStatusAlert], now: Date = Date()) async {
        var events: [AlertEvent] = []
        var current: Set<String> = []
        for alert in alerts {
            let severity = AlertSeverity.of(source: alert.source)
            guard severity >= policy.minSeverity else { continue }
            current.insert(alert.source)
            if let sent = active[alert.source], now.timeIntervalSince(sent.at) < policy.cooldown { continue }
            active[alert.source] = Sent(at: now, severity: severity)
            events.append(
                AlertEvent(
                    source: alert.source, severity: severity, state: .firing, message: alert.message, host: host,
                    timestamp: now))
        }
        for (source, sent) in active.sorted(by: { $0.key < $1.key }) where !current.contains(source) {
            active[source] = nil
            guard policy.notifyOnResolve else { continue }
            events.append(
                AlertEvent(
                    source: source, severity: sent.severity, state: .resolved, message: "no longer raised", host: host,
                    timestamp: now))
        }
        for event in events { await deliver(event) }
    }

    /// Sends one event to every sink; a failure is logged and the others still run.
    func deliver(_ event: AlertEvent) async {
        for sink in sinks {
            await bestEffortAsync("alerts", "delivering the \(event.source) alert") { try await sink.send(event) }
        }
    }
}
