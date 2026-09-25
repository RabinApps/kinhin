import AppKit
import KinhinKit

// Status item construction, menu rendering, and the pure state -> title mapping.

@MainActor
extension AppDelegate {
    // MARK: Status item & menu

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
        applyFleetControlVisibility(to: m, status: lastStatus)

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

    // MARK: Status rendering (pure, unit-tested)

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

    /// The first menu line: state word, counters, and the org-scope per-repo
    /// summaries (top 2 each) when the fleet serves more than one repo.
    /// Static so the Fleet tab can render the exact same line.
    func statusLine(for status: FleetStatus) -> String {
        AppDelegate.statusLineText(for: status)
    }

    /// Shared rendering of the status line for the menu and the Fleet tab.
    static func statusLineText(for status: FleetStatus?) -> String {
        guard let status else { return "Needs setup — open the Setup tab" }
        let state = !status.running ? "Stopped" : (status.paused ? "Paused" : "Running")
        var line = "\(state) — queue \(status.queueDepth) · desired \(status.desired) · cap \(status.capacityCap)"
        if status.jobCapacity > 0 { line += " · \(status.jobCapacity) job slots" }
        // Org scope: which repos the queued work comes from.
        if let byRepo = status.queueByRepo, status.queueDepth > 0, !byRepo.isEmpty {
            let top = byRepo.sorted { $0.value > $1.value }.prefix(2)
            let summary = top.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            line += "\n  ↳ \(summary)"
        }
        // Org scope: which repos the running work comes from.
        if let byRepo = status.runningByRepo, status.activeCount > 0, !byRepo.isEmpty {
            let top = byRepo.sorted { $0.value > $1.value }.prefix(2)
            let summary = top.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            line += "\n  ▶ \(summary)"
        }
        return line
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

    func apply(status: FleetStatus?) {
        lastStatus = status
        applyFleetControlVisibility(to: menu, status: status)
        // Title reflects state at a glance.
        if let status {
            statusItem?.button?.title = statusTitle(for: status)
            statusLineItem?.title = statusLine(for: status)
        } else {
            statusItem?.button?.title = "○"
            statusLineItem?.title = AppDelegate.statusLineText(for: nil)
        }

        rebuildVMSection(status: status)
        mainController?.render(status: status)
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
            if let repos = record.repos, !repos.isEmpty {
                let reposText = repos.count == 1 ? repos[0] : "\(repos.count) repos"
                title += " — \(reposText)"
            }
            if let job = record.job { title += " (\(job))" }
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
