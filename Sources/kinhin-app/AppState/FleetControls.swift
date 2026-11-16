import KinhinKit

/// The one source for the fleet's Start / Stop / Pause / Resume controls: which are visible, what they say, and when
/// they are busy. The Fleet screen, the status-bar menu and the main menu all read this instead of each deciding
/// again, so a command in flight disables the same controls everywhere. A nil status (no engine or daemon reachable)
/// counts as stopped.
struct FleetControls: Equatable {
    enum Control: CaseIterable {
        case start, stop
        /// One control that pauses a running fleet and resumes a paused one.
        case pauseResume
    }

    /// Where a control is drawn: buttons say "Stop", the menu says "Stop Fleet".
    enum Surface { case screen, menu }

    let visibility: FleetControlVisibility
    /// A command in flight (a start, stop, requeue or skip): every control disables until it completes.
    let pending: FleetAction?

    init(status: FleetStatus?, pending: FleetAction?) {
        visibility = FleetControlVisibility(status: status)
        self.pending = pending
    }

    var isBusy: Bool { pending != nil }

    /// Resume while paused, Pause otherwise.
    var isResume: Bool { visibility.resume }

    func isVisible(_ control: Control) -> Bool {
        switch control {
        case .start: return visibility.start
        case .stop: return visibility.stop
        case .pauseResume: return visibility.pause || visibility.resume
        }
    }

    /// Visible and not blocked by a command in flight.
    func isEnabled(_ control: Control) -> Bool { isVisible(control) && !isBusy }

    /// The control carries a progress indicator: its own command is the one in flight.
    func showsProgress(_ control: Control) -> Bool {
        switch (control, pending) {
        case (.start, .start?), (.stop, .stop?): return true
        default: return false
        }
    }

    func title(_ control: Control, on surface: Surface = .screen) -> String {
        switch (control, surface) {
        case (.start, .screen):
            return showsProgress(.start)
                ? String(localized: "Starting…", bundle: .l10n, comment: "Fleet button while the fleet starts")
                : String(localized: "Start", bundle: .l10n, comment: "Fleet button that starts the fleet")
        case (.stop, .screen):
            return showsProgress(.stop)
                ? String(localized: "Stopping…", bundle: .l10n, comment: "Fleet button while the fleet stops")
                : String(localized: "Stop", bundle: .l10n, comment: "Fleet button that stops the fleet")
        case (.pauseResume, .screen):
            return isResume
                ? String(localized: "Resume", bundle: .l10n, comment: "Fleet button that resumes a paused fleet")
                : String(localized: "Pause", bundle: .l10n, comment: "Fleet button that pauses the fleet")
        case (.start, .menu):
            return String(localized: "Start Fleet", bundle: .l10n, comment: "Status-bar menu item")
        case (.stop, .menu):
            return String(localized: "Stop Fleet", bundle: .l10n, comment: "Status-bar menu item")
        case (.pauseResume, .menu):
            return isResume
                ? String(localized: "Resume Fleet", bundle: .l10n, comment: "Status-bar menu item; toggles with Pause")
                : String(localized: "Pause Fleet", bundle: .l10n, comment: "Status-bar menu item; toggles with Resume")
        }
    }

    /// The menu shortcut: ⌘S start, ⌘K stop, ⌘P pause / ⌘R resume.
    func menuKey(_ control: Control) -> String {
        switch control {
        case .start: return "s"
        case .stop: return "k"
        case .pauseResume: return isResume ? "r" : "p"
        }
    }

    /// The spoken name of a button ("Stop the fleet"), distinct from its visible title.
    func accessibilityLabel(_ control: Control) -> String {
        switch control {
        case .start:
            return showsProgress(.start)
                ? String(
                    localized: "Starting the fleet", bundle: .l10n, comment: "VoiceOver label of the busy Start button")
                : String(localized: "Start the fleet", bundle: .l10n, comment: "VoiceOver label of the Start button")
        case .stop:
            return showsProgress(.stop)
                ? String(
                    localized: "Stopping the fleet", bundle: .l10n, comment: "VoiceOver label of the busy Stop button")
                : String(localized: "Stop the fleet", bundle: .l10n, comment: "VoiceOver label of the Stop button")
        case .pauseResume:
            return isResume
                ? String(
                    localized: "Resume the fleet", bundle: .l10n, comment: "VoiceOver label of the Resume button")
                : String(localized: "Pause the fleet", bundle: .l10n, comment: "VoiceOver label of the Pause button")
        }
    }
}

/// Which fleet actions apply to a state. A nil status (no engine or daemon
/// reachable) counts as stopped.
struct FleetControlVisibility: Equatable {
    let start: Bool
    let stop: Bool
    let pause: Bool
    let resume: Bool

    init(status: FleetStatus?) {
        let running = status?.running ?? false
        let paused = status?.paused ?? false
        start = !running
        stop = running
        pause = running && !paused
        resume = running && paused
    }
}
