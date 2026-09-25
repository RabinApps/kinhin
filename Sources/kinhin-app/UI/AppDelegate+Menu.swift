import AppKit
import KinhinKit

// Status item construction and menu rendering: the status line, the
// dynamic VM section, and the state -> title mapping — plus the single
// main window's wiring (tabs, launch modes, activation policy).
@MainActor
extension AppDelegate {
    // MARK: Application menu (menu bar while the app has a window)

    /// The standard macOS menu bar: app menu (Settings…, Quit), Edit (so
    /// copy/paste work in every field), and Window. Installed once; the
    /// status-bar menu below is separate.
    func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu(title: "kinhin")
        app.addItem(
            withTitle: "About kinhin", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(withTitle: "Settings…", action: #selector(openSettingsTab), keyEquivalent: ",")
        settings.target = self
        let setup = app.addItem(withTitle: "Setup…", action: #selector(openSetupTab), keyEquivalent: "")
        setup.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide kinhin", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit kinhin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    // MARK: Menu state

    /// Start/Stop/Pause/Resume only enable when they would do something.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.identifier?.rawValue else { return true }
        let running = lastStatus?.running ?? false
        let paused = lastStatus?.paused ?? false
        switch id {
        case "startFleet": return !running
        case "stopFleet": return running
        case "pauseFleet": return running && !paused
        case "resumeFleet": return running && paused
        default: return true
        }
    }

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

        m.addItem(.separator())
        let updateItem = m.addItem(
            withTitle: "Check for Updates…", action: #selector(updateItemClicked), keyEquivalent: "")
        updateItem.target = self
        updateItem.identifier = NSUserInterfaceItemIdentifier("updateItem")
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

    @MainActor
    func apply(status: FleetStatus?) {
        lastStatus = status
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

    @MainActor
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

    // MARK: Main window & tabs

    /// Opens (or focuses) the main window and makes kinhin a regular app
    /// while it is visible.
    @objc func openMainWindow() {
        if mainController == nil {
            let controller = MainTabsWindowController()
            controller.delegate = self
            controller.runtimesEdited = { [weak self] in
                self?.pushConfigToEngine()
            }
            controller.tokenSaved = { [weak self] forge, token in
                try await self?.notifyTokenReplaced(forge: forge, token: token)
            }
            mainController = controller
        }
        if setupIncomplete {
            mainController?.setupIncompleteFlag = true
        }
        isMainWindowVisible = true
        applyActivationPolicy()
        mainController?.showWindow(nil)
        mainController?.window?.makeKeyAndOrderFront(nil)
        mainController?.render(status: lastStatus)
        mainController?.applySetupInProgress()
        mainController?.refreshVisibleTab()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Tab shortcuts shared by the menu and the window's own buttons.
    @objc func openSetupTab() { openMainWindow(); mainController?.showSetup() }
    @objc func openSettingsTab() { openMainWindow(); mainController?.selectTab(.advanced) }

    /// Dock-icon clicks reopen the window when none is visible (normal-app
    /// behavior for the window-centric launch modes).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && AppPreferences.launchMode.showMainWindowAtLaunch {
            openMainWindow()
        }
        return true
    }

    // MARK: Actions

    @objc func startFleet() {
        Task {
            if let engine {
                await engine.start()
            } else if let client {
                _ = try? client.send(method: .start)
            } else {
                openSetupTab()
            }
            await refresh()
        }
    }

    @objc func stopFleet() {
        Task {
            if let engine {
                await engine.stop()
            } else if let client {
                _ = try? client.send(method: .stop)
            }
            await refresh()
        }
    }

    @objc func pauseFleet() {
        Task {
            if let engine {
                await engine.setPaused(true)
            } else if let client {
                _ = try? client.send(method: .pause)
            }
            await refresh()
        }
    }

    @objc func resumeFleet() {
        Task {
            if let engine {
                await engine.setPaused(false)
            } else if let client {
                _ = try? client.send(method: .resume)
            }
            await refresh()
        }
    }

    @objc func deleteVM(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        deleteVM(id: id)
    }

    func deleteVM(id: String) {
        let alert = NSAlert()
        alert.messageText = "Delete \(id)?"
        alert.informativeText = "This stops the VM and removes it. Any job running on it is cancelled."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard confirmDestructive(alert) else { return }
        Task {
            if let engine {
                await engine.deleteVM(id: id)
            } else if let client {
                let payload = try? JSONEncoder().encode(Daemon.VMDeleteRequest(id: id))
                _ = try? client.send(method: .deleteVM, payload: payload)
            }
            await refresh()
        }
    }

    /// Runs a confirmation alert; overridable in tests via `confirmOverride`.
    func confirmDestructive(_ alert: NSAlert) -> Bool {
        if let confirmOverride { return confirmOverride }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Config writes (Runtimes pane, Config tab) reach whoever owns the
    /// engine so the running fleet picks up the change. Routing-only edits
    /// apply live; anything else (scope, bounds, VM shape, images, forge
    /// sections) restarts the engine automatically — the old behavior was
    /// to silently keep the stale config until a manual daemon restart.
    /// Edits are debounced: a save burst (e.g. a stepper drag) flushes once.
    func pushConfigToEngine() {
        pendingConfigEdits = true
        guard !isConfigPushScheduled else { return }
        isConfigPushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            while self.pendingConfigEdits {
                self.pendingConfigEdits = false
                await self.applyConfigToEngine()
            }
            self.isConfigPushScheduled = false
        }
    }

    private func applyConfigToEngine() async {
        if let engine {
            guard let cfg = try? ConfigLoader.load() else {
                Log.warn(
                    "app",
                    "config reload skipped — config.yaml does not parse; the running fleet keeps its current config")
                return
            }
            if FleetEngine.restartRequired(from: engine.activeConfig, to: cfg) {
                await rebuildInProcessEngine(from: engine, config: cfg)
            } else {
                engine.applyReloaded(config: cfg, host: ResourceProbe().snapshot())
                Log.info("app", "routing reloaded into in-process engine")
            }
        } else if let client {
            do {
                _ = try client.reloadConfig()
                Log.info("app", "daemon notified: config reloaded (restarted if the change required it)")
            } catch {
                Log.warn("app", "daemon reload failed: \(error.localizedDescription)")
            }
        }
        await refresh()
    }

    /// Rebuild the in-process engine from a new config. Deliberately not
    /// stop()→start(): stop tears every active VM down. The old engine is
    /// detached (scaling stops, lifecycle tasks cancel) while its instances
    /// keep running; the replacement adopts them via the standard recovery
    /// path, then resumes serving at the previous running/paused state.
    private func rebuildInProcessEngine(from old: FleetEngine, config cfg: kinhinConfig) async {
        guard let pat = ConfigLoader.engineToken(for: cfg) else {
            Log.warn(
                "app",
                "config change needs an engine restart but the required forge token is missing — the fleet keeps running on the old config"
            )
            return
        }
        do {
            let tart = try cfg.makeTartControlling()
            let wasRunning = await old.status().running
            let wasPaused = await old.status().paused
            let replacement = FleetEngine(
                config: cfg,
                pat: pat,
                tart: tart,
                store: FleetStore(),
                ssh: SSHExecutor(),
                host: ResourceProbe().snapshot()
            )
            // A stopped fleet stays stopped across a rebuild — a config edit
            // must never start spawning VMs.
            if wasRunning {
                await replacement.start()
                if wasPaused { await replacement.setPaused(true) }
            }
            let status = await replacement.status()
            if wasRunning, !status.running, let error = status.lastError {
                // Startup verification failed (bad PAT, transient network):
                // keep the old engine instead of trading a running fleet for
                // a dead one.
                Log.error("app", "rebuild did not start: \(error) — keeping the previous engine and config")
                return
            }
            await old.detachKeepingInstances()
            engine = replacement
            Log.info(
                "app",
                "config change required a restart — engine rebuilt (running: \(wasRunning), paused: \(wasPaused))")
        } catch {
            Log.error(
                "app",
                "engine rebuild failed: \(error.localizedDescription) — the fleet keeps running on the old config")
        }
    }

    @objc func openLogs() {
        let url = URL(fileURLWithPath: Paths.logsDirectory.path)
        NSWorkspace.shared.open(url)
    }

    /// When tart is installed but Gatekeeper kills it on launch, the wizard
    /// alone isn't enough — run the repair directly (no UI dependency).
    func runTartRepairIfNeeded() {
        let cfg = try? ConfigLoader.load()
        guard TartController.isInstalled(configuredPath: cfg?.tartPath) else { return }
        Task {
            let health = await TartHealthProbe(configuredPath: cfg?.tartPath).check()
            guard health == .killedOnLaunch else { return }
            Log.error("app", "tart is killed on launch; starting automatic rollback repair")
            let repair = TartHealthProbe.repairs(for: .killedOnLaunch)[0]
            let repairRunner = SetupWindowController(embeddedIn: NSView())
            repairRunner.runRepair(
                repair,
                progressTitle: "Tart is blocked by Gatekeeper — rolling back to the notarized Cirrus Labs build…"
            )
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - MainTabsWindowDelegate

@MainActor
extension AppDelegate: MainTabsWindowDelegate, NSMenuItemValidation {
    func openLogsFolder() { openLogs() }
    func checkForUpdatesNow() { updateItemClicked() }

    func launchModeChanged(_ mode: LaunchMode) {
        applyActivationPolicy()
        // Match the status item to the mode without touching a status item
        // that is already installed (or removed).
        if mode.showsStatusItem && statusItem == nil {
            installStatusItem()
        } else if !mode.showsStatusItem, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            menu = nil
        }
    }

    func launchAtLoginChanged(_ enabled: Bool) {
        LaunchAtLoginService.apply(enabled: enabled)
    }

    func mainTabsWindowWillClose() {
        isMainWindowVisible = false
        applyActivationPolicy()
        if shouldQuitOnMainWindowClose(launchMode: AppPreferences.launchMode) {
            quit()
        }
    }

    /// The setup checklist's Start Fleet was pressed: rebuild the engine
    /// from the now-complete config and hand the window back to the Fleet tab.
    func setupTabFinished() {
        setupIncomplete = false
        mainController?.setupIncompleteFlag = false
        engine = nil
        client = nil
        bootstrapEngine(reopenSetupOnFailure: false)
        guard engine != nil || client != nil else {
            // Not ready after all: say why instead of silently resetting the
            // wizard (the old behavior looked like "Start fleet does nothing").
            setupIncomplete = true
            mainController?.setupIncompleteFlag = true
            let alert = NSAlert()
            alert.messageText = "kinhin can't start the fleet yet"
            alert.informativeText =
                "Setup isn't complete: connect GitHub or Gitea and choose a repository, and make sure tart is installed. Open the Setup tab to finish."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            mainController?.showSetup()
            return
        }
        // "Start fleet" means start it: bootstrapping alone only builds the engine.
        startFleet()
    }
}
