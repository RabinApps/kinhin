import Foundation

/// What the healing agent asks an advisor: one problem no rule answers (or
/// whose fixes are spent), the fixes it may pick from, and a little context.
public struct HealingAdviceRequest: Sendable, Equatable {
    public let signal: HealingSignal
    /// The allowlist for this problem. Anything outside it is ignored.
    public let candidates: [Remediation]
    /// Recent log lines about the problem, already redacted and trimmed.
    public let context: String

    public init(signal: HealingSignal, candidates: [Remediation], context: String) {
        self.signal = signal
        self.candidates = candidates
        self.context = LogRedactor.redact(context)
    }
}

/// An advisor's answer: one candidate by its kind (`Remediation.Kind` raw
/// value), or none, and a one-sentence explanation for the user.
public struct HealingAdvice: Sendable, Equatable {
    /// A candidate's kind raw value, or nil for "none of them".
    public let remediation: String?
    /// The advisor's own confidence. A doubtful pick is surfaced, never run.
    public let confident: Bool
    public let explanation: String
    /// The model that answered, when the advisor runs more than one (the
    /// Ollama cascade); nil means the advisor's own name.
    public let model: String?

    /// True when `confident` is the model's own say-so rather than a measured
    /// probability. Such a pick is never run without approval.
    public let selfReported: Bool

    public init(
        remediation: String?, confident: Bool, explanation: String, model: String? = nil, selfReported: Bool = false
    ) {
        self.remediation = remediation
        self.confident = confident
        self.explanation = explanation
        self.model = model
        self.selfReported = selfReported
    }
}

/// Picks a fix for problems the playbook does not cover. The agent, not the
/// advisor, enforces the guardrails: the pick must be one of the candidates,
/// its tier comes from `Remediation.Kind`, and a doubtful pick only surfaces.
public protocol HealingAdvisor: Sendable {
    /// For the snapshot and the journal ("apple-intelligence").
    var name: String { get }
    /// Whether the advisor can answer right now (the model is ready).
    func isAvailable() async -> Bool
    /// One answer; nil or a throw both mean "no advice".
    func advise(_ request: HealingAdviceRequest) async throws -> HealingAdvice?
}

/// No advisor: problems no rule covers are surfaced to the user.
public struct NoHealingAdvisor: HealingAdvisor {
    public init() {}
    public var name: String { "none" }
    public func isAvailable() async -> Bool { false }
    public func advise(_ request: HealingAdviceRequest) async throws -> HealingAdvice? { nil }
}

/// A fixed answer, for the e2e suite (debug builds read it from
/// `KINHIN_HEALING_ADVISOR`): `stub:<kind>` always picks that kind,
/// `stub:invalid` picks something outside every allowlist, `stub:doubtful:<kind>`
/// picks the kind without confidence.
public struct StubHealingAdvisor: HealingAdvisor {
    let pick: String?
    let confident: Bool

    public init(pick: String?, confident: Bool = true) {
        self.pick = pick
        self.confident = confident
    }

    /// Parses the env spec; nil when it is not a stub spec.
    public init?(spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.first == "stub", parts.count >= 2 else { return nil }
        if parts[1] == "doubtful", parts.count == 3 {
            self.init(pick: parts[2], confident: false)
        } else if parts[1] == "invalid" {
            self.init(pick: "run_shell_command")
        } else {
            self.init(pick: parts[1])
        }
    }

    public var name: String { "stub" }
    public func isAvailable() async -> Bool { true }
    public func advise(_ request: HealingAdviceRequest) async throws -> HealingAdvice? {
        HealingAdvice(remediation: pick, confident: confident, explanation: "stub advisor picked \(pick ?? "nothing")")
    }
}
