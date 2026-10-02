import AppKit
import KinhinKit

// Status item construction, menu rendering, and the pure state -> title mapping.

@MainActor
extension AppDelegate {
    // MARK: - Status item & menu

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "○"
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

        m.addItem(withTitle: "kinhin", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(.separator())

        let statusLine = m.addItem(withTitle: "Loading…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        statusLine.identifier = NSUserInterfaceItemIdentifier("statusLine")

        m.addItem(.separator())

        // Opens the main window (the launch-mode setting decides whether it
        // also opens at launch). Always present: in menu-bar-only mode this
        // is the only way in, and in main-window-and-menu-bar mode it
        // re-opens a closed window.
        let openItem = m.addItem(withTitle: "Open kinhin", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        openItem.identifier = NSUserInterfaceItemIdentifier("openMainWindow")

        // Shortcuts into the window's tabs.
        let setupItem = m.addItem(withTitle: "Setup…", action: #selector(openSetupTab), keyEquivalent: "")
        setupItem.target = self
        setupItem.identifier = NSUserInterfaceItemIdentifier("openSetupTab")
        let settingsItem = m.addItem(withTitle: "Settings…", action: #selector(openSettingsTab), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.identifier = NSUserInterfaceItemIdentifier("openSettingsTab")

        m.addItem(.separator())
        for (title, action, key, id) in [
            ("Start Fleet", #selector(startFleet), "s", "startFleet"),
            ("Stop Fleet", #selector(stopFleet), "k", "stopFleet"),
            ("Pause", #selector(pauseFleet), "p", "pauseFleet"),
            ("Resume", #selector(resumeFleet), "r", "resumeFleet"),
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
            withTitle: "Update available…", action: #selector(updateItemClicked), keyEquivalent: "")
        updateItem.target = self
        updateItem.identifier = NSUserInterfaceItemIdentifier("updateItem")
        updateItem.isHidden = true
        let versionItem = m.addItem(withTitle: "  kinhin \(kinhinVersion.current)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        m.addItem(withTitle: "Open Logs", action: #selector(openLogs), keyEquivalent: "").target = self
        let supportItem = m.addItem(
            withTitle: "Support kinhin…", action: #selector(openSupportPage), keyEquivalent: "")
        supportItem.target = self
        supportItem.identifier = NSUserInterfaceItemIdentifier("supportKinhin")
        m.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self

        // Placeholder VM section refreshed dynamically.
        m.addItem(.separator())
        let vmHeader = m.addItem(withTitle: "VMs", action: nil, keyEquivalent: "")
        vmHeader.isEnabled = false
        vmHeader.identifier = NSUserInterfaceItemIdentifier("vmSectionStart")

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
            case "pauseFleet": item.isHidden = !visibility.pause
            case "resumeFleet": item.isHidden = !visibility.resume
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
    /// otherwise the shared state line.
    func statusLineText(pending: FleetAction?, status: FleetStatus?) -> String {
        if let pending { return pending == .start ? "Starting…" : "Stopping…" }
        guard let status else { return fleet.statusLine }
        return statusLine(for: status)
    }

    /// Renders the status item and menu from the fleet controller's state.
    func renderFleetState() {
        let status = fleet.status
        let pending = fleet.pendingFleetAction
        applyFleetControlVisibility(to: menu, status: status)
        applySetupItemVisibility(to: menu)
        statusItem?.button?.title = statusItemTitle(pending: pending, status: status)
        renderStatusLines(statusLineText(pending: pending, status: status))
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

    /// Rebuilds the dynamic VM rows between the "VMs" header and the trailing
    /// separator. Internal (not private) so tests can drive the rebuild
    /// against a real menu. Idempotent: stale rows are removed first.
    func rebuildVMSection(status: FleetStatus?) {
        guard let menu else { return }
        // Remove everything between the "VMs" header and the trailing separator.
        guard let startIdx = menu.items.firstIndex(where: { $0.identifier?.rawValue == "vmSectionStart" }) else {
            return
        }
        while menu.items.count > startIdx + 1 {
            menu.removeItem(at: startIdx + 1)
        }
        guard let status, !status.records.isEmpty else {
            let none = menu.addItem(withTitle: "  (no VMs)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            return
        }
        for record in status.records {
            var title = "  \(record.id) — \(record.phase.rawValue)"
            if let repos = FleetStatusFormatter.repos(of: record) { title += " — \(repos)" }
            if let job = record.job { title += " (\(job))" }
            if let usage = FleetStatusFormatter.usage(of: record) { title += " · \(usage)" }
            if let err = record.error { title += " ⚠︎ \(err.prefix(40))" }
            let item = menu.addItem(withTitle: title, action: #selector(deleteVM(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = record.id
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
