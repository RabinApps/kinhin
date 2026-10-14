import Foundation

/// What the healing agent needs from whoever runs the fleet: the problems as
/// signals, the fixes carried out, and somewhere to publish its state. The
/// engine is the production conformance (`FleetEngine+Healing`); the agent's
/// unit tests use a scripted one.
protocol HealingActions: Sendable {
    /// Every current problem, one signal per problem.
    func healingSignals(now: Date) async -> [HealingSignal]
    /// Carries one fix out; returns what happened, throws when it failed.
    func perform(_ fix: Remediation) async throws -> String
    /// Recent, redacted log lines about `signal` for the advisor.
    func healingContext(for signal: HealingSignal) -> String
    /// What the playbook needs to know about the config.
    var healingPlaybookContext: HealingPlaybook.Context { get }
    /// Makes the snapshot visible (status) and raises or clears the `healing` alert.
    func publish(_ snapshot: HealingSnapshot, alert: String?) async
}
