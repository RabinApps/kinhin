import AppKit
import KinhinKit

// MARK: - MainTabsWindowDelegate

@MainActor
extension AppDelegate: MainTabsWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    // MARK: - NSMenuDelegate

    /// An open menu shows live fleet data (CPU/RAM included): poll at the
    /// fast cadence while it is up.
    func menuWillOpen(_ menu: NSMenu) { fleet.setMenuOpen(true) }

    func menuDidClose(_ menu: NSMenu) { fleet.setMenuOpen(false) }

    func openLogsFolder() { openLogs() }

    func openConfig() {
        // Open the config file in the user's editor; no file copy, no editor session.
        NSWorkspace.shared.open(Paths.config)
    }

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

    /// "Reset kinhin…" wiped the chosen scope. Config-scoped resets also
    /// cleared the launch-at-login preference: remove the system registration
    /// to match. Then re-bootstrap — with the config gone the wizard comes
    /// back; a daemon-scoped reset just re-probes without forcing a window.
    func resetFinished(scope: ResetScope) {
        if scope != .daemon {
            LaunchAtLoginService.apply(enabled: false)
        }
        Task {
            await bootstrapEngine(reopenSetupOnFailure: scope != .daemon)
        }
    }

    /// The setup checklist's Start Fleet was pressed: rebuild the engine
    /// from the now-complete config and hand the window back to the Fleet tab.
    func setupTabFinished() {
        setupIncomplete = false
        fleet.backend = nil
        Task {
            await bootstrapEngine(reopenSetupOnFailure: false)
            guard fleet.service != nil else {
                // Not ready after all: say why instead of silently resetting the
                // wizard (the old behavior looked like "Start fleet does nothing").
                setupIncomplete = true
                AlertKit.notice(
                    "kinhin can't start the fleet yet",
                    "Setup isn't complete: connect GitHub or Gitea and choose a repository, and make sure tart is installed. Open the Setup tab to finish."
                )
                mainController?.tabs.showSetup()
                return
            }
            // "Start fleet" means start it: bootstrapping alone only builds the engine.
            startFleet()
        }
    }
}
