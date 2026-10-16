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

    /// The Settings toggle: `WindowModels` shows a failure and puts the toggle back to the real state.
    func launchAtLoginChanged(_ enabled: Bool) throws {
        try LaunchAtLoginService.apply(enabled: enabled)
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
            do {
                try LaunchAtLoginService.apply(enabled: false)
            } catch {
                // The reset cleared the preference; a login item left behind would reopen kinhin anyway.
                AlertKit.present(error: error, title: LaunchAtLoginService.alertTitle)
            }
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
                    String(
                        localized: "kinhin can't start the fleet yet", bundle: .l10n,
                        comment: "Alert title when Start Fleet is pressed before setup finished"),
                    // The bootstrap's own reason (config unreadable, engine
                    // build failed) beats the generic checklist hint.
                    fleet.problems[.launch]
                        ?? String(
                            localized:
                                "Setup isn't complete: connect GitHub or Gitea and choose a repository, and make sure tart is installed. Open the Setup tab to finish.",
                            bundle: .l10n, comment: "Alert body when Start Fleet is pressed before setup finished")
                )
                mainController?.tabs.showSetup()
                return
            }
            // "Start fleet" means start it: bootstrapping alone only builds the engine.
            startFleet()
        }
    }
}
