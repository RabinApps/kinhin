import AppKit
import KinhinKit

// The single main window: tabs, launch modes, and activation policy.

@MainActor
extension AppDelegate {
    // MARK: - Main window & tabs

    /// Opens (or focuses) the main window and makes kinhin a regular app
    /// while it is visible.
    @objc func openMainWindow() {
        if mainController == nil {
            let controller = MainTabsWindowController(fleet: fleet, updates: updates)
            controller.delegate = self
            controller.models.runtimesEdited = { [weak self] in
                self?.fleet.pushConfigToEngine()
            }
            controller.models.tokenSaved = { [weak self] forge, token in
                try await self?.notifyTokenReplaced(forge: forge, token: token)
            }
            controller.models.accountTokenSaved = { [weak self] account, token in
                try await self?.notifyAccountTokenReplaced(account: account, token: token)
            }
            mainController = controller
        }
        isMainWindowVisible = true
        applyActivationPolicy()
        mainController?.showWindow(nil)
        mainController?.window?.makeKeyAndOrderFront(nil)
        mainController?.tabs.applySetupInProgress()
        mainController?.tabs.refreshVisibleTab()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Tab shortcuts shared by the menu and the window's own buttons.
    @objc func openSetupTab() { openMainWindow(); mainController?.tabs.showSetup() }
    @objc func openSettingsTab() { openMainWindow(); mainController?.tabs.select(.advanced) }

    /// Dock-icon clicks reopen the window when none is visible (normal-app
    /// behavior for the window-centric launch modes).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && AppPreferences.launchMode.showMainWindowAtLaunch {
            openMainWindow()
        }
        return true
    }
}
