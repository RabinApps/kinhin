import Foundation

/// One problem the healing agent can see, normalized from the engine's alerts,
/// records, spawn backoff and setup checks. The same problem seen on every pass
/// produces the same `key`, which is what budgets, pending approvals and
/// dismissals are tracked by.
public struct HealingSignal: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A record with no lifecycle (a warm instance, typically) whose
        /// instance was stopped or deleted out of band. Subject: the instance.
        case instanceGone = "instance_gone"
        /// A teardown that keeps failing; the record stays `.deleting`. Subject: the instance.
        case teardownStuck = "teardown_stuck"
        /// Spawns are held because free disk is below the reserve.
        case diskPressure = "disk_pressure"
        /// A runtime's runners keep failing to start (spawn backoff). Subject: the runtime.
        case spawnFailures = "spawn_failures"
        /// An account could not be attached. Subject: the account.
        case accountDetached = "account_detached"
        /// A token is missing or the Keychain cannot be read.
        case credentials
        /// A forge's queue could not be read. Subject: the account.
        case queueUnreadable = "queue_unreadable"
        /// The reconcile pass itself keeps throwing.
        case reconcileFailing = "reconcile_failing"
        /// A failing setup check (`kinhin setup status`). Subject: the check id.
        case setupCheck = "setup_check"
    }

    /// What the engine learned while building the signal, when it probed.
    public enum Evidence: String, Codable, Sendable {
        case instanceStopped = "instance_stopped"
        case runtimeMissing = "runtime_missing"
        case runtimeBroken = "runtime_broken"
        case containerSystemStopped = "container_system_stopped"
        case tartKilledOnLaunch = "tart_killed_on_launch"
        case tartBroken = "tart_broken"
        case authRejected = "auth_rejected"
    }

    public var kind: Kind
    public var subject: String?
    /// Human-readable, token-free description of what is wrong.
    public var detail: String
    public var evidence: Evidence?
    /// The setup check's stable action id (`setupCheck` only).
    public var setupAction: String?

    public init(
        kind: Kind, subject: String? = nil, detail: String, evidence: Evidence? = nil, setupAction: String? = nil
    ) {
        self.kind = kind
        self.subject = subject
        self.detail = LogRedactor.redact(detail)
        self.evidence = evidence
        self.setupAction = setupAction
    }

    /// Stable identity across passes: the kind and its subject.
    public var key: String { subject.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue }
}
