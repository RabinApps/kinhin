import AppKit
import KinhinKit

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
        let wizard = OnboardingWizardViewController()
        wizard.saveToken = { [weak self] forge, token in
            try await self?.tokenSaved?(forge, token)
        }
        wizard.saveAccountToken = { [weak self] account, token in
            try await self?.accountTokenSaved?(account, token)
        }
        wizard.onFinished = { [weak self] in
            // Setup is done: the Setup tab goes away for good.
            self?.setupIncompleteFlag = false
            self?.tabViews[.setup] = nil
            self?.wizardController = nil
            self?.selectTab(.fleet, notify: false)
            self?.delegate?.setupTabFinished()
        }
        wizard.onFinishLater = { [weak self] in
            // Leave setup as it is; the Setup tab stays until it is finished.
            self?.selectTab(.fleet, notify: false)
        }
        wizardController = wizard
        pin(wizard.view, in: tab)
        return tab
    }

    /// Advanced → Accounts: the same Connect and This Mac forms the wizard
    /// uses, for changing them after setup.
    func buildAccountsSection() -> NSView {
        let tab = NSView()
        let connect = ConnectFormViewController()
        connect.saveToken = { [weak self] forge, token in
            try await self?.tokenSaved?(forge, token)
        }
        connect.model.accounts.saveToken = { [weak self] account, token in
            try await self?.accountTokenSaved?(account, token)
        }
        connect.hasStoredToken = tokenProbe
        connect.onChanged = { [weak self] in self?.runtimesEdited?() }
        let mac = MacToolsFormViewController()
        mac.onChanged = { [weak self] in self?.runtimesEdited?() }
        connectController = connect
        macToolsController = mac

        let (scroll, column) = FormKit.scrollingColumn(spacing: 14)
        column.addArrangedSubview(FormKit.sectionHeader("Connect"))
        column.addArrangedSubview(connect.view)
        column.addArrangedSubview(FormKit.sectionHeader("This Mac"))
        column.addArrangedSubview(mac.view)
        tab.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: tab.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: tab.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: tab.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: tab.trailingAnchor),
        ])
        return tab
    }
}
