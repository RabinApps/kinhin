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
        loginHint.font = .systemFont(ofSize: 10)
        loginHint.textColor = .tertiaryLabelColor
        loginHint.preferredMaxLayoutWidth = FormKit.formWidth - 28
        launchColumn.addArrangedSubview(FormKit.row([modeLabel, modePopup]))
        launchColumn.addArrangedSubview(settingsSubtitle)
        launchColumn.addArrangedSubview(loginCheck)
        launchColumn.addArrangedSubview(loginHint)

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

    @objc func loginToggled() {
        let enabled = loginCheck.state == .on
        AppPreferences.setLaunchAtLogin(enabled, in: prefs)
        delegate?.launchAtLoginChanged(enabled)
    }
}
