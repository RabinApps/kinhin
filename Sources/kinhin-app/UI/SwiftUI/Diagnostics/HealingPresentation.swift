import Foundation
import KinhinKit

/// The healing agent's snapshot flattened for the Diagnostics sheet: the
/// policy, what waits on the user, and the recent history. A value type so
/// tests can pin the layout without loading any UI.
struct HealingPresentation: Equatable {
    /// One journal entry as the sheet shows it.
    struct Item: Identifiable, Equatable {
        let id: String
        /// What happened or what to do (from KinhinKit, token-free).
        let detail: String
        /// The advisor's reasoning; nil unless the on-device model picked the fix.
        let explanation: String?
        let outcome: HealingEvent.Outcome
        let outcomeLabel: String
        /// When the entry last changed.
        let updatedAt: Date

        /// A fix that worked, or a problem that went away.
        var ok: Bool { outcome == .succeeded || outcome == .resolved }
    }

    /// How many closed events the history shows.
    static let historyLimit = 10

    let enabled: Bool
    /// What runs on its own and what waits.
    let policy: String
    /// Who advises on problems no rule covers. Nil while healing is off.
    let advisor: String?
    /// Fixes waiting for approval, newest first.
    let pending: [Item]
    /// Problems only the user can fix, newest first.
    let surfaced: [Item]
    /// Fixes being carried out right now.
    let running: [Item]
    /// The last closed events, newest first.
    let history: [Item]

    init(_ snapshot: HealingSnapshot) {
        enabled = snapshot.enabled
        if !snapshot.enabled {
            policy = String(
                localized: "Off — kinhin does not fix problems on its own (healing.enabled is false).", bundle: .l10n,
                comment:
                    "Diagnostics healing policy when healing is disabled; healing.enabled is a config key, verbatim")
            advisor = nil
        } else {
            policy =
                snapshot.automatic
                ? String(
                    localized: "Safe fixes run automatically; the rest wait for your approval.", bundle: .l10n,
                    comment: "Diagnostics healing policy when automatic fixes are on")
                : String(
                    localized: "Approval only: every fix waits for you.", bundle: .l10n,
                    comment: "Diagnostics healing policy when automatic fixes are off (healing.auto: none)")
            advisor =
                snapshot.advisor.map { name in
                    String(
                        localized: "Advisor: \(name)", bundle: .l10n,
                        comment: "Diagnostics healing advisor line; %@ is the advisor's name (the on-device model)")
                }
                ?? String(
                    localized: "Rules only — no advisor available.", bundle: .l10n,
                    comment: "Diagnostics healing advisor line when no on-device model advises")
        }
        pending = snapshot.pending.map(Item.init)
        surfaced = snapshot.surfaced.map(Item.init)
        running = snapshot.events.filter { $0.outcome == .running }.map(Item.init)
        history = snapshot.events.filter { !$0.isOpen }.prefix(Self.historyLimit).map(Item.init)
    }

    /// Nothing waits on the user, nothing runs and nothing has happened yet.
    var isQuiet: Bool { pending.isEmpty && surfaced.isEmpty && running.isEmpty && history.isEmpty }

    /// A short, localized name for an outcome.
    static func label(for outcome: HealingEvent.Outcome) -> String {
        switch outcome {
        case .pending:
            return String(localized: "Needs approval", bundle: .l10n, comment: "Healing event outcome")
        case .running:
            return String(localized: "Running", bundle: .l10n, comment: "Healing event outcome")
        case .succeeded:
            return String(localized: "Fixed", bundle: .l10n, comment: "Healing event outcome: the fix worked")
        case .failed:
            return String(localized: "Fix failed", bundle: .l10n, comment: "Healing event outcome")
        case .surfaced:
            return String(
                localized: "Needs you", bundle: .l10n, comment: "Healing event outcome: only the user can fix it")
        case .dismissed:
            return String(localized: "Dismissed", bundle: .l10n, comment: "Healing event outcome")
        case .resolved:
            return String(
                localized: "Went away", bundle: .l10n,
                comment: "Healing event outcome: the problem cleared before anyone acted")
        case .expired:
            return String(
                localized: "Expired", bundle: .l10n,
                comment: "Healing event outcome: left open when the fleet stopped")
        }
    }
}

extension HealingPresentation.Item {
    init(_ event: HealingEvent) {
        self.init(
            id: event.id, detail: event.detail, explanation: event.source == .advisor ? event.explanation : nil,
            outcome: event.outcome, outcomeLabel: HealingPresentation.label(for: event.outcome),
            updatedAt: event.updatedAt)
    }
}
