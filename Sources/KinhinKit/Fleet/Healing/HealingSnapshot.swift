import Foundation

/// The healing agent's state as clients see it, carried on `FleetStatus`.
public struct HealingSnapshot: Codable, Sendable, Equatable {
    /// `healing.enabled`.
    public var enabled: Bool
    /// Whether automatic-tier fixes run on their own (`healing.auto: safe`).
    public var automatic: Bool
    /// The advisor consulted for problems no rule covers, when one is
    /// available (the on-device model); nil when off or unavailable.
    public var advisor: String?
    /// The journal, newest first.
    public var events: [HealingEvent]

    public init(enabled: Bool, automatic: Bool, advisor: String?, events: [HealingEvent]) {
        self.enabled = enabled
        self.automatic = automatic
        self.advisor = advisor
        self.events = events
    }

    /// Fixes waiting for approval, newest first.
    public var pending: [HealingEvent] { events.filter { $0.outcome == .pending } }

    /// Problems shown to the user that only they can fix.
    public var surfaced: [HealingEvent] { events.filter { $0.outcome == .surfaced } }

    /// Nothing waits on the user.
    public var healthy: Bool { pending.isEmpty && surfaced.isEmpty }

    /// How many closed entries `forStatus` keeps.
    public static let statusHistory = 10

    /// The part of the journal a status poll carries: every open entry and the
    /// newest `history` closed ones. The full journal is `healing_status`'s.
    public func forStatus(history: Int = HealingSnapshot.statusHistory) -> HealingSnapshot {
        var closed = 0
        let kept = events.filter { event in
            if event.isOpen { return true }
            closed += 1
            return closed <= history
        }
        return HealingSnapshot(enabled: enabled, automatic: automatic, advisor: advisor, events: kept)
    }

    /// The journal a stopped engine left on disk: its history, with entries
    /// that were still open read as expired (nobody can act on them now).
    public static func stored(
        in directory: URL = Paths.stateDirectory, policy: KinhinConfig.HealingConfig
    ) -> HealingSnapshot {
        let journal = HealingJournal.load(from: HealingJournal.fileURL(in: directory), readOnly: true)
        return HealingSnapshot(
            enabled: policy.enabled, automatic: policy.auto == .safe, advisor: nil, events: journal.newestFirst)
    }
}
