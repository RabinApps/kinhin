import AppKit
import KinhinKit

// MARK: - MainTabsWindowDelegate

@MainActor
extension AppDelegate: MainTabsWindowDelegate, NSMenuItemValidation {
    func openLogsFolder() { openLogs() }

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
