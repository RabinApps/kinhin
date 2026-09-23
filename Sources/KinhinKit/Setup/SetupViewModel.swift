import CoreGraphics
import Foundation

/// Pure presentation logic for the setup window: row mapping, progress math,
/// headline copy, and layout sizing. Lives in KinhinKit so it is unit-test
/// covered; the app target only renders what this computes.

/// One displayable row of the setup checklist.
public struct SetupRowViewModel: Equatable, Sendable {
    public let id: String
    public let title: String
    /// Shown under the title; never empty (falls back to a checking message).
    public let subtitle: String
    public let isSatisfied: Bool
    /// Label for the fix button, or nil when nothing to do.
    public let actionTitle: String?
    /// Stable action identifier driving the fix button ("install_tart", …).
    /// This — not the row id — is what the UI must dispatch on.
    public let actionID: String?
    /// True for "Checking this Mac…" placeholder rows while probes run.
    public let isPlaceholder: Bool

    public static let checkingSubtitle = "Checking this Mac…"

    /// VoiceOver label: state plus the available action, in one phrase.
    public var accessibilityLabel: String {
        if isPlaceholder { return title }
        var label = "\(title): \(isSatisfied ? "OK" : "needs setup")"
        if let actionTitle {
            label += " — action available: \(actionTitle)"
        }
        return label
    }

    /// Maps a contract check onto a display row.
    public init(check: SetupCheckResult) {
        self.id = check.id
        self.title = check.title
        self.subtitle = check.detail.isEmpty ? Self.checkingSubtitle : check.detail
        self.isSatisfied = check.ok
        self.actionID = check.action
        self.actionTitle = check.action.map { SetupAction.title(for: $0) }
        self.isPlaceholder = false
    }

    /// A placeholder row shown while the real probes run.
    public static func placeholder(index: Int) -> SetupRowViewModel {
        SetupRowViewModel(
            id: "placeholder-\(index)",
            title: "Checking this Mac…",
            subtitle: Self.checkingSubtitle,
            isSatisfied: false,
            actionID: nil,
            actionTitle: nil,
            isPlaceholder: true
        )
    }

    init(id: String, title: String, subtitle: String, isSatisfied: Bool, actionID: String?, actionTitle: String?, isPlaceholder: Bool) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isSatisfied = isSatisfied
        self.actionID = actionID
        self.actionTitle = actionTitle
        self.isPlaceholder = isPlaceholder
    }
}

/// The whole window's presentation state.
public struct SetupViewModel: Equatable, Sendable {
    public let rows: [SetupRowViewModel]
    public let ready: Bool
    public let canStart: Bool
    /// Fraction of checks satisfied, 0.0 ... 1.0.
    public let progressFraction: Double
    public let headline: String
    public let isLoading: Bool

    public init(checks: [SetupCheckResult], isLoading: Bool = false) {
        self.isLoading = isLoading
        if isLoading || checks.isEmpty {
            // Placeholder state: mirror the standard checklist length.
            self.rows = (0 ..< 6).map { SetupRowViewModel.placeholder(index: $0) }
            self.ready = false
            self.canStart = false
            self.progressFraction = 0
            self.headline = SetupRowViewModel.checkingSubtitle
            return
        }
        self.rows = checks.map(SetupRowViewModel.init(check:))
        let satisfied = checks.filter(\.ok).count
        self.ready = satisfied == checks.count
        self.canStart = self.ready
        self.progressFraction = checks.isEmpty ? 0 : Double(satisfied) / Double(checks.count)
        self.headline = self.ready
            ? "You're all set — start the fleet whenever you like."
            : "\(checks.count - satisfied) of \(checks.count) steps to go."
    }

    public init(status: SetupStatus) {
        self.init(checks: status.checks, isLoading: false)
    }
}

/// Pure layout math for the setup window (shared constants + sizing rules).
public enum SetupWindowLayout {
    public static let windowWidth: CGFloat = 620
    /// Header + footer + margins + six 64pt cards with 12pt spacing (the
    /// standard checklist grew to six rows when CLT was added).
    public static let windowHeight: CGFloat = 632
    public static let margin: CGFloat = 22
    public static let headerHeight: CGFloat = 88
    public static let footerHeight: CGFloat = 56
    public static let rowSpacing: CGFloat = 12
    public static let cardHeight: CGFloat = 64
    public static let cardCornerRadius: CGFloat = 10

    /// Card rows fully visible before the list must scroll.
    public static func visibleRowCount(windowHeight: CGFloat = windowHeight) -> Int {
        let available = windowHeight - headerHeight - footerHeight - margin * 2
        guard available >= cardHeight else { return 0 }
        return Int((available + rowSpacing) / (cardHeight + rowSpacing))
    }

    /// Window height needed to show `rows` cards without scrolling.
    public static func windowHeight(forRows rows: Int) -> CGFloat {
        let minimum = headerHeight + footerHeight + margin * 2 + cardHeight
        guard rows > 1 else { return max(windowHeight, minimum) }
        let needed = headerHeight + footerHeight + margin * 2
            + CGFloat(rows) * cardHeight + CGFloat(rows - 1) * rowSpacing
        return max(windowHeight, needed)
    }
}
