import Foundation

/// Turns successive snapshots of the fleet's active problems into `AlertEvent`s and delivers them.
///
/// A source that appears fires once; while it stays raised it fires again only after `cooldown`; when it
/// clears and a firing was sent, a `resolved` follows (if `notifyOnResolve`). A delivery that fails is kept and
/// tried again after `retryInterval` (a firing that never arrived is not held back by the cooldown, and a
/// resolution is not forgotten). A failing sink is logged and never reported back as a fleet problem, so a dead
/// endpoint cannot raise the alert that it then fails to send.
actor AlertDispatcher {
    struct Policy: Sendable, Equatable {
        var minSeverity: AlertSeverity = .warning
        var cooldown: TimeInterval = 3_600
        var notifyOnResolve = true
        /// How long to wait before sending an alert again after a failed delivery.
        var retryInterval: TimeInterval = 60
    }

    private struct Sent {
        var at: Date
        var severity: AlertSeverity
        var delivered: Bool
    }

    private struct PendingResolve {
        var event: AlertEvent
        var attemptedAt: Date?
    }

    private let sinks: [any AlertSink]
    private let policy: Policy
    private let host: String
    private var active: [String: Sent] = [:]
    private var pendingResolves: [String: PendingResolve] = [:]

    init(sinks: [any AlertSink], policy: Policy, host: String = ProcessInfo.processInfo.hostName) {
        self.sinks = sinks
        self.policy = policy
        self.host = host
    }

    /// Compares `alerts` (every problem active now) with what was last sent, and delivers the difference.
    func observe(_ alerts: [FleetStatusAlert], now: Date = Date()) async {
        var current: Set<String> = []
        for alert in alerts {
            let severity = AlertSeverity.of(source: alert.source)
            guard severity >= policy.minSeverity else { continue }
            current.insert(alert.source)
            // Raised again before its resolution got through: the resolution no longer applies.
            pendingResolves[alert.source] = nil
            if let sent = active[alert.source] {
                let wait = sent.delivered ? policy.cooldown : policy.retryInterval
                if now.timeIntervalSince(sent.at) < wait { continue }
            }
            let event = AlertEvent(
                source: alert.source, severity: severity, state: .firing, message: alert.message, host: host,
                timestamp: now)
            let delivered = await deliver(event)
            if Task.isCancelled { return }
            active[alert.source] = Sent(at: now, severity: severity, delivered: delivered)
        }
        for (source, sent) in active.sorted(by: { $0.key < $1.key }) where !current.contains(source) {
            active[source] = nil
            guard policy.notifyOnResolve, sent.delivered else { continue }
            pendingResolves[source] = PendingResolve(
                event: AlertEvent(
                    source: source, severity: sent.severity, state: .resolved, message: "no longer raised",
                    host: host, timestamp: now),
                attemptedAt: nil)
        }
        await flushResolves(now: now)
    }

    /// Sends the resolutions that are due; one that fails stays for the next attempt.
    private func flushResolves(now: Date) async {
        for (source, pending) in pendingResolves.sorted(by: { $0.key < $1.key }) {
            if let attempted = pending.attemptedAt, now.timeIntervalSince(attempted) < policy.retryInterval {
                continue
            }
            if await deliver(pending.event) {
                pendingResolves[source] = nil
            } else if !Task.isCancelled {
                pendingResolves[source]?.attemptedAt = now
            }
        }
    }

    /// Sends one event to every sink; a failure is logged and the others still run. True when every sink took it.
    func deliver(_ event: AlertEvent) async -> Bool {
        var delivered = true
        for sink in sinks {
            do {
                try await sink.send(event)
            } catch is CancellationError {
                return false
            } catch {
                Log.warn("alerts", "delivering the \(event.source) alert failed: \(error.localizedDescription)")
                delivered = false
            }
        }
        return delivered
    }
}
