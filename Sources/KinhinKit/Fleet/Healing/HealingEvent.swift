import Foundation

/// One entry of the healing journal: a fix that ran, waits for approval, or
/// was surfaced for the user, and how it ended.
public struct HealingEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        /// Waiting for approval.
        case pending
        /// Being carried out.
        case running
        case succeeded
        case failed
        /// Shown to the user; nothing kinhin can do on its own.
        case surfaced
        /// The user dismissed it.
        case dismissed
        /// The problem went away before anyone acted.
        case resolved
        /// Left pending when the engine stopped; re-raised if the problem persists.
        case expired
    }

    /// Who picked the fix.
    public enum Source: String, Codable, Sendable {
        case playbook
        /// The on-device model, choosing from the allowlisted candidates.
        case advisor
    }

    public let id: String
    public var signal: HealingSignal
    /// Nil when nothing in the allowlist fits and the problem is only surfaced.
    public var remediation: Remediation?
    public var source: Source
    public var outcome: Outcome
    /// What happened, or what the user should do. Token-free.
    public var detail: String {
        didSet { if LogRedactor.redact(detail) != detail { detail = LogRedactor.redact(detail) } }
    }
    /// The advisor's one-sentence reasoning, when it picked the fix.
    public var explanation: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = HealingEvent.newID(), signal: HealingSignal, remediation: Remediation?, source: Source,
        outcome: Outcome, detail: String, explanation: String? = nil, at now: Date = Date()
    ) {
        self.id = id
        self.signal = signal
        self.remediation = remediation
        self.source = source
        self.outcome = outcome
        self.detail = LogRedactor.redact(detail)
        self.explanation = explanation.map(LogRedactor.redact)
        self.createdAt = now
        self.updatedAt = now
    }

    /// Short ids a person can type: `h-` and 8 hex digits.
    public static func newID() -> String {
        String(format: "h-%08x", UInt32.random(in: 0..<UInt32.max))
    }

    /// The fix's tier, when there is a fix.
    public var tier: Remediation.Tier? { remediation?.tier }

    /// Still open: waiting on the user or on kinhin.
    public var isOpen: Bool { outcome == .pending || outcome == .running || outcome == .surfaced }
}
