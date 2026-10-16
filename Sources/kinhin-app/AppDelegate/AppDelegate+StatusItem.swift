import AppKit
import KinhinKit

// Status item construction, menu rendering, and the pure state -> title mapping.

@MainActor
extension AppDelegate {
    // MARK: - Status item & menu

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "○"
        item.button?.setAccessibilityLabel(
            String(
                localized: "kinhin, not running", bundle: .l10n,
                comment: "VoiceOver label of the status-bar item before the first poll"))
        let m = buildMenu()
        menu = m
        item.menu = m
        statusItem = item
    }

    /// Builds the status-bar menu. Factored out of installStatusItem so tests
    /// can construct and assert on the menu without touching the system
    /// status bar.
    func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self  // menuWillOpen/menuDidClose drive the poll cadence

        m.addItem(withTitle: "kinhin", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(.separator())

        let statusLine = m.addItem(
            withTitle: String(
                localized: "Loading…", bundle: .l10n,
                comment: "Placeholder status line in the status-bar menu until the first poll"), action: nil,
            keyEquivalent: "")
        statusLine.isEnabled = false
        statusLine.identifier = NSUserInterfaceItemIdentifier("statusLine")

        // The VM rows sit directly under the status line (extra status lines
        // land between the two). `rebuildVMSection` owns everything between
        // the header and the end marker.
        let vmHeader = m.addItem(
            withTitle: String(
                localized: "VMs", bundle: .l10n, comment: "Status-bar menu section header above the VM list"),
            action: nil, keyEquivalent: "")
        vmHeader.isEnabled = false
        vmHeader.identifier = NSUserInterfaceItemIdentifier("vmSectionStart")
        let vmEnd = NSMenuItem.separator()
        vmEnd.identifier = NSUserInterfaceItemIdentifier("vmSectionEnd")
        m.addItem(vmEnd)

        // Opens the main window (the launch-mode setting decides whether it
        // also opens at launch). Always present: in menu-bar-only mode this
        // is the only way in, and in main-window-and-menu-bar mode it
        // re-opens a closed window.
        let openItem = m.addItem(
            withTitle: String(
                localized: "Open kinhin", bundle: .l10n, comment: "Status-bar menu item that opens the main window"),
            action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        openItem.identifier = NSUserInterfaceItemIdentifier("openMainWindow")

        // Shortcuts into the window's tabs.
        let setupItem = m.addItem(
            withTitle: String(localized: "Setup…", bundle: .l10n, comment: "Menu item that opens the Setup tab"),
            action: #selector(openSetupTab), keyEquivalent: "")
        setupItem.target = self
        setupItem.identifier = NSUserInterfaceItemIdentifier("openSetupTab")
        let settingsItem = m.addItem(
            withTitle: String(localized: "Settings…", bundle: .l10n, comment: "Menu item that opens Settings"),
            action: #selector(openSettingsTab), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.identifier = NSUserInterfaceItemIdentifier("openSettingsTab")

        m.addItem(.separator())
        for (title, action, key, id) in [
            (
                String(localized: "Start Fleet", bundle: .l10n, comment: "Status-bar menu item"), #selector(startFleet),
                "s", "startFleet"
            ),
            (
                String(localized: "Stop Fleet", bundle: .l10n, comment: "Status-bar menu item"), #selector(stopFleet),
                "k", "stopFleet"
            ),
            (
                String(localized: "Pause", bundle: .l10n, comment: "Status-bar menu item; toggles with Resume"),
                #selector(togglePauseFleet), "p", "pauseResumeFleet"
            ),
        ] as [(String, Selector, String, String)] {
            let item = m.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command]
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(id)
        }
        applyFleetControlVisibility(to: m, status: fleet.status)
        applySetupItemVisibility(to: m)

        m.addItem(.separator())
        // Hidden until a background check finds a newer release; manual checks
        // live in Settings → App.
        let updateItem = m.addItem(
            withTitle: String(
                localized: "Update available…", bundle: .l10n,
                comment: "Status-bar menu item, hidden until a newer release is found"),
            action: #selector(updateItemClicked), keyEquivalent: "")
        updateItem.target = self
        updateItem.identifier = NSUserInterfaceItemIdentifier("updateItem")
        updateItem.isHidden = true
        let versionItem = m.addItem(
            withTitle: String(
                localized: "  kinhin \(kinhinVersion.current)", bundle: .l10n,
                comment: "Disabled version row in the status-bar menu; %@ is the version"), action: nil,
            keyEquivalent: "")
        versionItem.isEnabled = false
        m.addItem(
            withTitle: String(
                localized: "Open Logs", bundle: .l10n, comment: "Status-bar menu item that opens the Logs tab"),
            action: #selector(openLogs), keyEquivalent: ""
        ).target = self
        let supportItem = m.addItem(
            withTitle: String(
                localized: "Support kinhin…", bundle: .l10n, comment: "Menu item that opens the support page"),
            action: #selector(openSupportPage), keyEquivalent: "")
        supportItem.target = self
        supportItem.identifier = NSUserInterfaceItemIdentifier("supportKinhin")

        m.addItem(.separator())
        m.addItem(
            withTitle: String(localized: "Quit", bundle: .l10n, comment: "Status-bar menu item that quits the app"),
            action: #selector(quit), keyEquivalent: "q"
        ).target = self

        return m
    }

    private var statusLineItem: NSMenuItem? {
        menu?.items.first { $0.identifier?.rawValue == "statusLine" }
    }

    // MARK: - Status rendering (pure, unit-tested)

    /// The status-bar title for a fleet state: plain circle when idle or
    /// stopped, ⏸ when paused, and an active-VM count when busy.
    func statusTitle(for status: FleetStatus) -> String {
        switch (status.running, status.paused, status.activeCount) {
        case (false, _, _):
            return "○"
        case (true, true, _):
            return "○⏸"
        case (true, false, 0):
            return "○"
        case (true, false, let n):
            return "○ \(n)"
        }
    }

    /// The first menu line (shared with the Fleet tab): state word,
    /// counters, and the org-scope per-repo summaries.
    func statusLine(for status: FleetStatus) -> String {
        FleetStatusFormatter.summary(status)
    }

    /// Hides the fleet actions that make no sense in the current state.
    /// Items stay in the menu (hidden, not removed) so indices are stable.
    func applyFleetControlVisibility(to menu: NSMenu?, status: FleetStatus?) {
        guard let menu else { return }
        let visibility = FleetControlVisibility(status: status)
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "startFleet": item.isHidden = !visibility.start
            case "stopFleet": item.isHidden = !visibility.stop
            case "pauseResumeFleet":
                // One toggle: Pause while running, Resume while paused, gone when stopped.
                item.isHidden = !(visibility.pause || visibility.resume)
                item.title =
                    visibility.resume
                    ? String(localized: "Resume", bundle: .l10n, comment: "Status-bar menu item; toggles with Pause")
                    : String(localized: "Pause", bundle: .l10n, comment: "Status-bar menu item; toggles with Resume")
                item.keyEquivalent = visibility.resume ? "r" : "p"
            default: break
            }
        }
    }

    /// "Setup…" only matters until setup is done; Settings covers the rest.
    func applySetupItemVisibility(to menu: NSMenu?) {
        menu?.items.first { $0.identifier?.rawValue == "openSetupTab" }?.isHidden = !setupIncomplete
    }

    /// The status-bar button title: a spinner glyph while a start/stop is in
    /// flight (the poll's last word is stale until the command completes),
    /// otherwise the state circle / active-VM count.
    func statusItemTitle(pending: FleetAction?, status: FleetStatus?) -> String {
        if pending != nil { return "⟳" }
        guard let status else { return "○" }
        return statusTitle(for: status)
    }

    /// The menu's first line: "Starting…"/"Stopping…" while a command runs,
    /// otherwise the shared state line plus any app-side problem.
    func statusLineText(pending: FleetAction?, status: FleetStatus?) -> String {
        if let pending {
            return pending == .start
                ? String(localized: "Starting…", bundle: .l10n, comment: "Status line while a start command runs")
                : String(localized: "Stopping…", bundle: .l10n, comment: "Status line while a stop command runs")
        }
        let base = status.map(statusLine(for:)) ?? fleet.statusLine
        // App-side failures (launch, config push) sit under the state line.
        return fleet.problemLines.reduce(base) { $0 + "\n  ⚠ \($1)" }
    }

    /// Everything the status item and menu show that comes from the fleet
    /// state. Equal states render identically, so an unchanged poll skips the
    /// render (rebuilding the VM rows and status lines on every poll was the
    /// bulk of an idle app's main-thread work).
    struct MenuViewState: Equatable {
        struct VMRow: Equatable {
            let id: String
            let title: String
        }
        var itemTitle: String
        /// What VoiceOver says for the status item ("kinhin, 2 runners, paused").
        var accessibilityLabel: String
        var statusText: String
        var visibility: FleetControlVisibility
        var setupVisible: Bool
        var rows: [VMRow]
    }

    func menuViewState() -> MenuViewState {
        let status = fleet.status
        let pending = fleet.pendingFleetAction
        return MenuViewState(
            itemTitle: statusItemTitle(pending: pending, status: status),
            accessibilityLabel: Self.statusItemAccessibilityLabel(pending: pending, status: status),
            statusText: statusLineText(pending: pending, status: status),
            visibility: FleetControlVisibility(status: status),
            setupVisible: setupIncomplete,
            rows: (status?.records ?? []).map { MenuViewState.VMRow(id: $0.id, title: Self.menuRowTitle(for: $0)) })
    }

    /// The status item's accessibility label: the glyph title ("○ 2") reads as
    /// "white circle 2", so say it in words, e.g. "kinhin, 2 runners, paused".
    static func statusItemAccessibilityLabel(pending: FleetAction?, status: FleetStatus?) -> String {
        if let pending {
            switch pending {
            case .start:
                return String(
                    localized: "kinhin, starting", bundle: .l10n,
                    comment: "VoiceOver label of the status-bar item while the fleet starts")
            case .stop:
                return String(
                    localized: "kinhin, stopping", bundle: .l10n,
                    comment: "VoiceOver label of the status-bar item while the fleet stops")
            case .requeueQueuedJobs, .skipQueuedJobs:
                return String(
                    localized: "kinhin, updating the queue", bundle: .l10n,
                    comment: "VoiceOver label of the status-bar item while the queue is updated")
            }
        }
        guard let status, status.running else {
            return String(
                localized: "kinhin, not running", bundle: .l10n,
                comment: "VoiceOver label of the status-bar item when the fleet is stopped")
        }
        let n = status.activeCount
        if status.paused {
            return String(
                localized: "kinhin, \(n) runners, paused", bundle: .l10n,
                comment: "VoiceOver label of the status-bar item; plural by runner count; the fleet is paused")
        }
        return String(
            localized: "kinhin, \(n) runners", bundle: .l10n,
            comment: "VoiceOver label of the status-bar item; plural by runner count")
    }

    static func menuRowTitle(for record: VMRecord) -> String {
        var title = "  \(record.id) — \(record.phase.rawValue)"
        if let repos = FleetStatusFormatter.repos(of: record) { title += " — \(repos)" }
        if let job = record.job { title += " (\(job))" }
        if let usage = FleetStatusFormatter.usage(of: record) { title += " · \(usage)" }
        if let err = record.error { title += " ⚠︎ \(err.prefix(40))" }
        return title
    }

    /// Renders the status item and menu from the fleet controller's state,
    /// unless nothing they show has changed since the last render.
    func renderFleetState() {
        let state = menuViewState()
        let menuIdentity = menu.map(ObjectIdentifier.init)
        guard state != lastRenderedMenuState || menuIdentity != lastRenderedMenuIdentity else { return }
        lastRenderedMenuState = state
        lastRenderedMenuIdentity = menuIdentity
        let status = fleet.status
        applyFleetControlVisibility(to: menu, status: status)
        applySetupItemVisibility(to: menu)
        statusItem?.button?.title = state.itemTitle
        statusItem?.button?.setAccessibilityLabel(state.accessibilityLabel)
        renderStatusLines(state.statusText)
        rebuildVMSection(status: status)
    }

    /// An NSMenuItem title is a single line (newlines collapse to spaces), so the
    /// status text goes in as one disabled row per line: the first in the status
    /// item itself, the rest as rows right below it. Idempotent: earlier rows are
    /// removed first.
    func renderStatusLines(_ text: String) {
        guard let menu, let first = statusLineItem, let index = menu.items.firstIndex(of: first) else { return }
        while index + 1 < menu.items.count, menu.items[index + 1].identifier?.rawValue == "statusLineExtra" {
            menu.removeItem(at: index + 1)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        first.title = lines.first ?? text
        for (offset, line) in lines.dropFirst().enumerated() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("statusLineExtra")
            item.isEnabled = false
            menu.insertItem(item, at: index + 1 + offset)
        }
    }

    /// Rebuilds the dynamic VM rows between the "VMs" header and the end
    /// marker. Internal (not private) so tests can drive the rebuild against a
    /// real menu. Idempotent: stale rows are removed first.
    func rebuildVMSection(status: FleetStatus?) {
        guard let menu else { return }
        guard let startIdx = menu.items.firstIndex(where: { $0.identifier?.rawValue == "vmSectionStart" }) else {
            return
        }
        while startIdx + 1 < menu.items.count, menu.items[startIdx + 1].identifier?.rawValue != "vmSectionEnd" {
            menu.removeItem(at: startIdx + 1)
        }
        var next = startIdx + 1
        guard let status, !status.records.isEmpty else {
            let none = NSMenuItem(
                title: String(
                    localized: "  (no VMs)", bundle: .l10n, comment: "Status-bar menu placeholder when there are no VMs"
                ), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.insertItem(none, at: next)
            return
        }
        for record in status.records {
            let item = NSMenuItem(
                title: Self.menuRowTitle(for: record), action: #selector(deleteVM(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = record.id
            menu.insertItem(item, at: next)
            next += 1
        }
    }
}

// MARK: - Fleet control visibility

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
