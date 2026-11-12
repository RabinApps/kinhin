import Foundation

/// How urgent a raised problem is. `critical` stops work or needs a person; `warning` is something the engine retries.
public enum AlertSeverity: String, Codable, Sendable, Comparable, CaseIterable {
    case warning
    case critical

    public static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs == .warning && rhs == .critical
    }

    /// The severity of a status alert, by the subsystem that raised it. The engine's own retries
    /// (spawn backoff, orphan sweeps) are warnings; everything else needs attention.
    static func of(source: String) -> AlertSeverity {
        switch source {
        case "spawn-backoff", "orphans": return .warning
        default: return .critical
        }
    }
}

/// One message to deliver to an `AlertSink`: a problem that started (`firing`) or went away (`resolved`).
public struct AlertEvent: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case firing, resolved
    }

    /// The raising subsystem (`"disk"`, `"credentials"`, `"queue:<account>"`…). Also the dedupe key.
    public var source: String
    public var severity: AlertSeverity
    public var state: State
    /// Already passed through `LogRedactor`.
    public var message: String
    public var host: String
    public var timestamp: Date

    public init(
        source: String, severity: AlertSeverity, state: State, message: String, host: String, timestamp: Date
    ) {
        self.source = source
        self.severity = severity
        self.state = state
        self.message = LogRedactor.redact(message)
        self.host = host
        self.timestamp = timestamp
    }

    /// One line for chat-style sinks: `[kinhin host] disk: message`.
    var summary: String {
        let prefix = state == .resolved ? "resolved" : severity.rawValue
        return "[kinhin \(host)] \(prefix) — \(source): \(message)"
    }
}
