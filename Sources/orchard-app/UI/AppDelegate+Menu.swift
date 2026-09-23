import AppKit
import OrchardKit

// Status item construction and menu rendering: the status line, the
// dynamic VM section, and the state -> title mapping.
@MainActor
extension AppDelegate {
    // MARK: Status item & menu

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🌳"
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

        m.addItem(withTitle: "Orchard", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(.separator())

        let statusLine = m.addItem(withTitle: "Loading…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        statusLine.identifier = NSUserInterfaceItemIdentifier("statusLine")

        m.addItem(.separator())

        m.addItem(withTitle: "Start Fleet", action: #selector(startFleet), keyEquivalent: "s").target = self
        m.addItem(withTitle: "Stop Fleet", action: #selector(stopFleet), keyEquivalent: "k").target = self
        m.addItem(withTitle: "Pause", action: #selector(pauseFleet), keyEquivalent: "p").target = self
        m.addItem(withTitle: "Resume", action: #selector(resumeFleet), keyEquivalent: "r").target = self
        m.addItem(withTitle: "Replace Access Token…", action: #selector(replaceTokenClicked), keyEquivalent: "t").target = self

        m.addItem(.separator())
        let updateItem = m.addItem(withTitle: "Check for Updates…", action: #selector(updateItemClicked), keyEquivalent: "")
        updateItem.target = self
        updateItem.identifier = NSUserInterfaceItemIdentifier("updateItem")
        let versionItem = m.addItem(withTitle: "  Orchard \(OrchardVersion.current)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        m.addItem(withTitle: "Open Setup…", action: #selector(openSetup), keyEquivalent: "").target = self
        m.addItem(withTitle: "Runtimes…", action: #selector(openRuntimes), keyEquivalent: "").target = self
        m.addItem(withTitle: "Open Logs", action: #selector(openLogs), keyEquivalent: "l").target = self
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

    /// The status-bar title for a fleet state: plain tree when idle or
    /// stopped, ⏸ when paused, and an active-VM count when busy.
    func statusTitle(for status: FleetStatus) -> String {
        switch (status.running, status.paused, status.activeCount) {
        case (false, _, _):
            return "🌳"
        case (true, true, _):
            return "🌳⏸"
        case (true, false, 0):
            return "🌳"
        case (true, false, let n):
            return "🌳 \(n)"
        }
    }

    /// The first menu line: state word, counters, and the org-scope per-repo
    /// summaries (top 2 each) when the fleet serves more than one repo.
    func statusLine(for status: FleetStatus) -> String {
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
        // Title reflects state at a glance.
        if let status {
            statusItem?.button?.title = statusTitle(for: status)
            statusLineItem?.title = statusLine(for: status)
        } else {
            statusItem?.button?.title = "🌳"
            statusLineItem?.title = "Needs setup — open Setup…"
        }

        rebuildVMSection(status: status)
    }

    @MainActor
    /// Rebuilds the dynamic VM rows between the "VMs" header and the trailing
    /// separator. Internal (not private) so tests can drive the rebuild
    /// against a real menu. Idempotent: stale rows are removed first.
    func rebuildVMSection(status: FleetStatus?) {
        guard let menu else { return }
        // Remove everything between the "VMs" header and the trailing separator.
        guard let startIdx = menu.items.firstIndex(where: { $0.identifier?.rawValue == "vmSectionStart" }) else { return }
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

    // MARK: Actions

    @objc func startFleet() {
        Task {
            if let engine {
                await engine.start()
            } else if let client {
                _ = try? client.send(method: .start)
            } else {
                openSetup()
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

    @objc func openRuntimes() {
        if runtimesController == nil {
            let controller = RuntimesWindowController()
            controller.onEdited = { [weak self] in
                // Push the routing change to whoever owns the engine so a
                // running fleet picks it up without a restart: the
                // in-process engine directly, a daemon over RPC. No engine
                // yet → nothing to reload; the next start reads the file.
                Task { [weak self] in
                    guard let self else { return }
                    if let engine = self.engine {
                        if let cfg = try? ConfigLoader.load() {
                            engine.applyReloaded(config: cfg, host: ResourceProbe().snapshot())
                            Log.info("app", "routing reloaded into in-process engine")
                        }
                    } else if let client = self.client {
                        do {
                            _ = try client.reloadConfig()
                            Log.info("app", "daemon notified: routing reloaded")
                        } catch {
                            Log.warn("app", "daemon reload failed: \(error.localizedDescription)")
                        }
                    }
                    await self.refresh()
                }
            }
            runtimesController = controller
        }
        runtimesController?.showWindow(nil)
        runtimesController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openLogs() {
        let url = URL(fileURLWithPath: Paths.logsDirectory.path)
        NSWorkspace.shared.open(url)
    }

    @objc func openSetup() {
        if setupController == nil {
            let controller = SetupWindowController()
            controller.onFinished = { [weak self] in
                self?.engine = nil
                self?.client = nil
                self?.bootstrapEngine()
            }
            setupController = controller
        }
        setupController?.showWindow(nil)
        setupController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { self.repairTartIfNeeded() }
    }

    /// When tart is installed but Gatekeeper kills it on launch, the checklist
    /// alone isn't enough — kick off the rollback repair automatically.
    private func repairTartIfNeeded() {
        let cfg = try? ConfigLoader.load()
        guard TartController.isInstalled(configuredPath: cfg?.tartPath) else { return }
        Task {
            let health = await TartHealthProbe(configuredPath: cfg?.tartPath).check()
            guard health == .killedOnLaunch else { return }
            Log.error("app", "tart is killed on launch; starting automatic rollback repair")
            setupController?.runRepair(
                TartHealthProbe.repairs(for: .killedOnLaunch)[0],
                progressTitle: "Tart is blocked by Gatekeeper — rolling back to the notarized Cirrus Labs build…"
            )
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
