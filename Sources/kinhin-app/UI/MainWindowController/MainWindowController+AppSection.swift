import AppKit
import KinhinKit

// The App section: launch behavior, files, and their persistence.
@MainActor
extension MainTabsWindowController {
    // MARK: App section (launch behavior, files)

    func buildAppSection() -> NSView {
        let tab = NSView()

        let (launchCard, launchColumn) = FormKit.card(title: "Launch")
        let modeLabel = FormKit.label("Show at launch")
        for mode in LaunchMode.allCases {
            modePopup.addItem(withTitle: mode.label)
            modePopup.lastItem?.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
        }
        modePopup.target = self
        modePopup.action = #selector(modePopupChanged)
        modePopup.setAccessibilityLabel("What kinhin shows at launch")
        settingsSubtitle.font = .systemFont(ofSize: 11)
        settingsSubtitle.textColor = .secondaryLabelColor
        settingsSubtitle.maximumNumberOfLines = 0
        settingsSubtitle.preferredMaxLayoutWidth = FormKit.formWidth - 28
        loginCheck.target = self
        loginCheck.action = #selector(loginToggled)
        loginCheck.setAccessibilityLabel("Launch kinhin at login")
        autoStartCheck.target = self
        autoStartCheck.action = #selector(autoStartToggled)
        autoStartCheck.setAccessibilityLabel("Start the fleet when kinhin opens")
        loginHint.font = .systemFont(ofSize: 10)
        loginHint.textColor = .tertiaryLabelColor
        loginHint.preferredMaxLayoutWidth = FormKit.formWidth - 28
        launchColumn.addArrangedSubview(FormKit.row([modeLabel, modePopup]))
        launchColumn.addArrangedSubview(settingsSubtitle)
        launchColumn.addArrangedSubview(loginCheck)
        launchColumn.addArrangedSubview(autoStartCheck)
        launchColumn.addArrangedSubview(loginHint)

        let (updatesCard, updatesColumn) = FormKit.card(title: "Updates")
        updateStatusLabel.font = .systemFont(ofSize: 11)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.maximumNumberOfLines = 0
        updateStatusLabel.preferredMaxLayoutWidth = FormKit.formWidth - 28
        updateStatusLabel.setAccessibilityIdentifier("update-status")
        updateButton.target = self
        updateButton.action = #selector(updateClicked)
        updateButton.bezelStyle = .rounded
        updateButton.identifier = NSUserInterfaceItemIdentifier("check-for-updates")
        updatesColumn.addArrangedSubview(FormKit.row([updateButton]))
        updatesColumn.addArrangedSubview(updateStatusLabel)
        renderUpdate(state: delegate?.updateCardState ?? .idle(lastChecked: nil))

        let (filesCard, filesColumn) = FormKit.card(
            title: "Files",
            subtitle: "Everything above is saved in config.yaml — open it for settings that have no control here."
        )
        let openConfig = NSButton(title: "Open config file", target: self, action: #selector(openConfigFileClicked))
        openConfig.bezelStyle = .rounded
        openConfig.identifier = NSUserInterfaceItemIdentifier("open-config-file")
        let openLogs = NSButton(title: "Open logs folder", target: self, action: #selector(logsClicked))
        openLogs.bezelStyle = .rounded
        filesColumn.addArrangedSubview(FormKit.row([openConfig, openLogs]))

        let (scroll, column) = FormKit.scrollingColumn()
        column.addArrangedSubview(launchCard)
        column.addArrangedSubview(updatesCard)
        column.addArrangedSubview(filesCard)
        tab.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: tab.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: tab.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: tab.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: tab.trailingAnchor),
        ])
        // Reflect stored prefs now that the controls exist.
        applyLaunchMode(AppPreferences.launchMode(in: prefs), notify: false)
        return tab
    }

    @objc func updateClicked() { delegate?.checkForUpdatesNow() }

    // MARK: Update card

    /// Renders the update check/download state into the Settings → App card.
    func renderUpdate(state: UpdateCardState) {
        let version = "kinhin \(kinhinVersion.current)"
        updateButton.isEnabled = true
        updateButton.title = "Check for Updates…"
        switch state {
        case .idle(let lastChecked):
            updateStatusLabel.stringValue = Self.lastCheckedText(version: version, lastChecked)
        case .checking:
            updateStatusLabel.stringValue = "\(version) — checking…"
            updateButton.isEnabled = false
        case .upToDate(let lastChecked):
            updateStatusLabel.stringValue = Self.lastCheckedText(version: "\(version) is up to date", lastChecked)
        case .available(let newVersion):
            updateStatusLabel.stringValue =
                "Update available — kinhin \(newVersion) (you have \(kinhinVersion.current))."
            updateButton.title = "Download…"
        case .downloading(let name):
            updateStatusLabel.stringValue = "Downloading \(name)…"
            updateButton.isEnabled = false
        case .failed(let message):
            updateStatusLabel.stringValue = "Update check failed: \(message)"
        }
    }

    private static func lastCheckedText(version: String, _ date: Date?) -> String {
        guard let date, date > .distantPast else { return version }
        return "\(version) — last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    @objc func openConfigFileClicked() {
        NSWorkspace.shared.open(Paths.config)
    }

    // MARK: Settings rendering

    /// Applies a launch mode to the Settings tab (and, when the user picked
    /// it from the popup, persists + notifies). `notify: false` is used at
    /// init to sync from stored prefs without re-persisting.
    func applyLaunchMode(_ mode: LaunchMode, notify: Bool = true) {
        let index = LaunchMode.allCases.firstIndex(of: mode) ?? 0
        modePopup.selectItem(at: index)
        settingsSubtitle.stringValue = mode.subtitle
        if notify {
            AppPreferences.setLaunchMode(mode, in: prefs)
            delegate?.launchModeChanged(mode)
        }
    }

    @objc func modePopupChanged() {
        guard let raw = modePopup.selectedItem?.identifier?.rawValue,
            let mode = LaunchMode(rawValue: raw)
        else { return }
        Log.info("app", "launch mode set to \(mode.rawValue)")
        applyLaunchMode(mode)
    }

    @objc func autoStartToggled() {
        AppPreferences.setAutoStartFleet(autoStartCheck.state == .on, in: prefs)
    }

    @objc func loginToggled() {
        let enabled = loginCheck.state == .on
        AppPreferences.setLaunchAtLogin(enabled, in: prefs)
        delegate?.launchAtLoginChanged(enabled)
    }
}
