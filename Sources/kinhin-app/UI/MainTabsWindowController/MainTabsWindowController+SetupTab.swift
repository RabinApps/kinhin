import AppKit
import KinhinKit
import SwiftUI

// The Setup tab: guided wizard until first-run setup completes, then editable forms.
@MainActor
extension MainTabsWindowController {
    // MARK: Setup tab

    /// While first-run setup is incomplete the window opens on the Setup tab,
    /// which shows the guided wizard.
    func applySetupInProgress() {
        guard isWindowLoaded else { return }
        if setupIncompleteFlag {
            showSetup()
        }
    }

    /// Opens setup: the guided wizard while setup is unfinished, otherwise the
    /// Accounts section of Advanced (there is no Setup tab after onboarding).
    func showSetup() {
        guard setupIncompleteFlag else {
            showAdvanced(.accounts)
            return
        }
        tabViews[.setup] = nil
        selectTab(.setup)
        Log.info("app", "guided setup shown")
    }

    /// The first-run wizard (the only content of the Setup tab).
    func buildSetupTab() -> NSView {
        let tab = NSView()
        tab.translatesAutoresizingMaskIntoConstraints = false
        let model = WizardModel()
        model.connect.saveToken = { [weak self] forge, token in
            try await self?.tokenSaved?(forge, token)
        }
        model.connect.accounts.saveToken = { [weak self] account, token in
            try await self?.accountTokenSaved?(account, token)
        }
        model.onFinished = { [weak self] in
            // Setup is done: the Setup tab goes away for good.
            self?.setupIncompleteFlag = false
            self?.tabViews[.setup] = nil
            self?.wizardModel = nil
            self?.selectTab(.fleet, notify: false)
            self?.delegate?.setupTabFinished()
        }
        model.onFinishLater = { [weak self] in
            // Leave setup as it is; the Setup tab stays until it is finished.
            self?.selectTab(.fleet, notify: false)
        }
        wizardModel = model
        let host = NSHostingView(rootView: WizardView(model: model))
        // The wizard fills whatever it is pinned into; its content scrolls.
        host.sizingOptions = []
        pin(host, in: tab)
        return tab
    }

    /// Advanced → Accounts: the same Connect and This Mac forms the wizard
    /// uses, for changing them after setup.
    func buildAccountsSection() -> NSView {
        let connect = ConnectModel()
        connect.saveToken = { [weak self] forge, token in
            try await self?.tokenSaved?(forge, token)
        }
        connect.accounts.saveToken = { [weak self] account, token in
            try await self?.accountTokenSaved?(account, token)
        }
        connect.hasStoredToken = tokenProbe
        connect.onChanged = { [weak self] in self?.runtimesEdited?() }
        let mac = MacToolsModel()
        mac.onChanged = { [weak self] in self?.runtimesEdited?() }
        connectModel = connect
        macToolsModel = mac
        connect.reload()
        mac.reload()

        let host = NSHostingView(rootView: AccountsSectionView(connect: connect, mac: mac))
        host.sizingOptions = []
        return host
    }
}
