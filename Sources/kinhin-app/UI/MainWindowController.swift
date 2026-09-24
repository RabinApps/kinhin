import AppKit
import KinhinKit

// MARK: - Pure decisions (unit-tested)

/// Decides which activation policy the app runs with. Kept as a pure,
/// unit-testable function so MainWindowTests can pin the normal-app behavior
/// without launching anything.
@MainActor
func activationPolicy(showingMainWindow: Bool, launchMode: LaunchMode) -> NSApplication.ActivationPolicy {
    // Any visible main window makes kinhin a real app (Dock icon + app menu).
    // In menu-bar-only mode there is never a window, so the policy stays
    // accessory; in the other two modes the app always presents a window
    // (at launch, or as soon as the user opens one).
    if showingMainWindow { return .regular }
    return launchMode.showsMainWindowWithoutBeingVisible ? .regular : .accessory
}

extension LaunchMode {
    /// Modes whose identity is the main window stay `.regular` even while the
    /// window is closed, so re-opening it (Dock, login item) feels like a
    /// normal app rather than flipping the process persona back and forth.
    var showsMainWindowWithoutBeingVisible: Bool { self != .menuBarOnly }
}

/// Whether closing the main window should terminate the app: only in
/// main-window-only mode, where the window is the whole app and a living
/// invisible process would be a zombie.
@MainActor
func shouldQuitOnMainWindowClose(launchMode: LaunchMode) -> Bool {
    launchMode == .mainWindowOnly
}

// MARK: - Tabs

/// The main window's tabs. Setup is NOT a tab: it is a top-right button that
/// overlays the whole window while onboarding (see showSetupOverlay).
enum MainTab: String, CaseIterable {
    case fleet
    case runtimes
    case tokens
    case settings
    case logs

    var label: String {
        switch self {
        case .fleet: return "Fleet"
        case .runtimes: return "Runtimes"
        case .tokens: return "Tokens"
        case .settings: return "Settings"
        case .logs: return "Logs"
        }
    }
}

// MARK: - Tab delegate

/// Everything the tabbed window needs from the app. The window stays free of
/// FleetEngine/RPC knowledge: tabs render state and ask the delegate to act,
/// mirroring how the status-bar menu targets the AppDelegate.
@MainActor
protocol MainTabsWindowDelegate: AnyObject {
    func startFleet()
    func stopFleet()
    func pauseFleet()
    func resumeFleet()
    func deleteVM(id: String)
    func openLogsFolder()
    func checkForUpdatesNow()
    func launchModeChanged(_ mode: LaunchMode)
    func launchAtLoginChanged(_ enabled: Bool)
    func mainTabsWindowWillClose()
    /// Setup finished (its Start Fleet was pressed): re-bootstrap the engine.
    func setupTabFinished()
}

// MARK: - Main tabs window

/// kinhin's single main window: a segmented control switches between Fleet,
/// Runtimes, Tokens, Settings, and Logs; Setup lives behind a top-right
/// button that overlays the window until onboarding completes.
@MainActor
final class MainTabsWindowController: NSWindowController, NSWindowDelegate {
    weak var delegate: MainTabsWindowDelegate?

    // Tab surfaces (created lazily on first selection).
    private var tabViews: [MainTab: NSView] = [:]
    private var setupView: NSView?
    private var isSetupOverlayActive = false

    // Header
    private let segmentControl = NSSegmentedControl(
        labels: MainTab.allCases.map(\.label),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let setupButton = NSButton(title: "Setup", target: nil, action: nil)
    private let tabContentContainer = NSView()

    // Embedded child controllers (created once with their tabs).
    private(set) var setupController: SetupWindowController?
    private(set) var runtimesController: RuntimesWindowController?
    private(set) var tokenController: TokenSettingsWindowController?
    private(set) var logsController: LogsViewController?
    private(set) var diagnosticsController: DiagnosticsViewController?
    /// The Runtimes tab's config writes must reach the engine/daemon; the
    /// app injects the same handler the standalone pane used.
    var runtimesEdited: (() -> Void)?
    /// The Tokens tab's saves persist to the Keychain and live-swap the
    /// engine token; the app injects the same handler the standalone form
    /// used. Throws on Keychain/RPC failure so the card shows the error.
    var tokenSaved: ((ForgeID, String) async throws -> Void)?

    // Fleet tab controls
    private let statusLineLabel = NSTextField(wrappingLabelWithString: "Loading…")
    private var isPaused = false
    private var pauseButton: NSButton?
    private var vmStack: NSStackView?
    private var jobsStack: NSStackView?

    // Settings tab controls
    private let settingsSubtitle = NSTextField(wrappingLabelWithString: "")
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loginCheck = NSButton(checkboxWithTitle: "Launch kinhin at login", target: nil, action: nil)
    private let loginHint = NSTextField(wrappingLabelWithString: "Applies to the installed kinhin.app — no effect while running unbundled from `swift run`.")
    /// Where the settings tab persists prefs. The real app uses .standard;
    /// tests inject a scratch suite.
    private var prefs: UserDefaults = .standard

    /// Latest fleet status, so a reopened window renders live data instantly.
    var lastStatus: FleetStatus?

    convenience init() {
        self.init(defaults: .standard)
    }

    convenience init(defaults: UserDefaults) {
        let size = NSSize(width: 620, height: 560)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "kinhin"
        window.titlebarAppearsTransparent = true
        window.appearance = nil // follow the system (light & dark)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = container
        window.center()
        window.minSize = NSSize(width: 620, height: 460)
        self.init(window: window)
        prefs = defaults
        window.delegate = self
        buildUI(in: container)
        // Tabs install themselves on selection (their views must be in the
        // hierarchy before constraints pin them to the container).
        selectTab(.fleet, notify: false)
        applyLaunchMode(AppPreferences.launchMode(in: prefs), notify: false)
        loginCheck.state = AppPreferences.launchAtLogin(in: prefs) ? .on : .off
        loginHint.isHidden = LaunchAtLoginService.isBundled
        render(status: nil)
    }

    // MARK: UI construction

    private func buildUI(in container: NSView) {
        container.wantsLayer = true

        segmentControl.target = self
        segmentControl.action = #selector(segmentChanged(_:))
        segmentControl.controlSize = .large
        segmentControl.translatesAutoresizingMaskIntoConstraints = false

        setupButton.bezelStyle = .rounded
        setupButton.controlSize = .large
        setupButton.target = self
        setupButton.action = #selector(setupButtonClicked)
        setupButton.setAccessibilityLabel("Open setup")
        setupButton.toolTip = "Set up kinhin: install tools, create config, store a token, prepare the runner image"

        let headerRow = NSStackView(views: [segmentControl, setupButton])
        headerRow.orientation = .horizontal
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        // The segments hug the left; Setup pins to the right edge.
        segmentControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        setupButton.setContentHuggingPriority(.required, for: .horizontal)
        headerRow.setCustomSpacing(200, after: segmentControl)

        tabContentContainer.wantsLayer = true
        tabContentContainer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(headerRow)
        container.addSubview(tabContentContainer)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            headerRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            headerRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            tabContentContainer.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 14),
            tabContentContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabContentContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabContentContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Tabs build lazily on first selection (installTab) so their views
        // are only pinned once they share the container's hierarchy.
    }

    // MARK: Tab switching

    private(set) var selectedTab: MainTab = .fleet

    func selectTab(_ tab: MainTab, notify: Bool = true) {
        selectedTab = tab
        isSetupOverlayActive = false
        segmentControl.selectedSegment = MainTab.allCases.firstIndex(of: tab) ?? 0
        tabContentContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let view = tabViews[tab] ?? installTab(tab) else { return }
        tabContentContainer.addSubview(view)
        // Pin the tab to the container now that both share a hierarchy.
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: tabContentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: tabContentContainer.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: tabContentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: tabContentContainer.trailingAnchor),
        ])
    }

    /// Creates a tab's view on first selection; nil for tabs without content.
    private func installTab(_ tab: MainTab) -> NSView? {
        let view: NSView?
        switch tab {
        case .fleet: view = buildFleetTab()
        case .runtimes: view = buildRuntimesTab()
        case .tokens: view = buildTokensTab()
        case .settings: view = buildSettingsTab()
        case .logs: view = buildLogsTab()
        }
        if let view { tabViews[tab] = view }
        return view
    }

    /// Refreshes whichever live-data tab is visible (called when the window
    /// shows or the user lands on a tab via the menu). Probes and config
    /// reads never run from bare tab switches — tests stay hermetic.
    func refreshVisibleTab() {
        switch selectedTab {
        case .runtimes:
            runtimesController?.reload()
        case .tokens:
            tokenController?.reload()
        case .logs:
            logsController?.refreshNow()
        case .fleet:
            Task { [diagnosticsController] in await diagnosticsController?.refreshIfVisible() }
        case .settings:
            break
        }
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard MainTab.allCases.indices.contains(index) else { return }
        Log.info("app", "tab → \(MainTab.allCases[index].rawValue)")
        selectTab(MainTab.allCases[index])
    }

    // MARK: Setup overlay (not a tab)

    @objc private func setupButtonClicked() {
        showSetupOverlay()
    }

    /// Covers the whole window with the setup checklist. Setup is not a tab:
    /// it is an onboarding surface behind a top-right button, shown on demand
    /// (and automatically while first-run setup is incomplete).
    func showSetupOverlay() {
        if setupView == nil {
            installSetupOverlay()
        }
        isSetupOverlayActive = true
        segmentControl.isEnabled = false
        setupButton.isEnabled = false
        tabContentContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let view = setupView else { return }
        tabContentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: tabContentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: tabContentContainer.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: tabContentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: tabContentContainer.trailingAnchor),
        ])
        Task { [setupController] in await setupController?.refreshChecks() }
        Log.info("app", "setup overlay shown")
    }

    private func installSetupOverlay() {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        let controller = SetupWindowController(embeddedIn: view)
        controller.onFinished = { [weak self] in
            self?.dismissSetupOverlay()
            self?.delegate?.setupTabFinished()
        }
        controller.onOpenTokenSettings = { [weak self] forge in
            // Token rows in the checklist jump to the Tokens tab.
            self?.dismissSetupOverlay()
            self?.selectTab(.tokens)
            self?.tokenController?.initialFocus = forge
        }
        self.setupController = controller
        setupView = view
    }

    private func dismissSetupOverlay() {
        isSetupOverlayActive = false
        segmentControl.isEnabled = true
        setupButton.isEnabled = true
        selectTab(.fleet, notify: false)
    }

    /// While first-run setup is incomplete the window opens straight into the
    /// checklist overlay (the Setup button is then redundant but harmless).
    func applySetupInProgress() {
        guard isWindowLoaded else { return }
        if setupIncompleteFlag {
            showSetupOverlay()
        }
    }

    /// Set by the app delegate before the window opens.
    var setupIncompleteFlag = false

    // MARK: Fleet tab

    private func buildFleetTab() -> NSView {
        let tab = NSView()
        tab.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "○  kinhin")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        statusLineLabel.font = .systemFont(ofSize: 12)
        statusLineLabel.textColor = .secondaryLabelColor
        statusLineLabel.maximumNumberOfLines = 3

        let headerStack = NSStackView(views: [title, statusLineLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(headerStack)

        let startButton = NSButton(title: "Start", target: self, action: #selector(startClicked))
        startButton.bezelStyle = .rounded
        startButton.setAccessibilityLabel("Start the fleet")
        let stopButton = NSButton(title: "Stop", target: self, action: #selector(stopClicked))
        stopButton.bezelStyle = .rounded
        stopButton.setAccessibilityLabel("Stop the fleet")
        let pause = NSButton(title: "Pause", target: self, action: #selector(pauseClicked))
        pause.bezelStyle = .rounded
        pause.setAccessibilityLabel("Pause or resume the fleet")
        pauseButton = pause

        let controlRow = NSStackView(views: [startButton, stopButton, pause])
        controlRow.orientation = .horizontal
        controlRow.spacing = 8
        controlRow.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(controlRow)

        // VMs
        let vmHeader = sectionHeader("VMs")
        let vmList = NSStackView()
        vmList.orientation = .vertical
        vmList.alignment = .leading
        vmList.spacing = 4
        vmList.translatesAutoresizingMaskIntoConstraints = false
        vmStack = vmList
        let vmScroll = NSScrollView()
        vmScroll.hasVerticalScroller = true
        vmScroll.drawsBackground = false
        vmScroll.documentView = vmList
        vmScroll.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(vmHeader)
        tab.addSubview(vmScroll)

        // Current jobs (which workflows are running right now, on which VM)
        let jobsHeader = sectionHeader("Current jobs")
        let jobs = NSStackView()
        jobs.orientation = .vertical
        jobs.alignment = .leading
        jobs.spacing = 3
        jobs.translatesAutoresizingMaskIntoConstraints = false
        jobsStack = jobs
        tab.addSubview(jobsHeader)
        tab.addSubview(jobs)

        let diagnosticsButton = NSButton(title: "Diagnostics…", target: self, action: #selector(diagnosticsClicked))
        diagnosticsButton.bezelStyle = .rounded
        let updateButton = NSButton(title: "Check for Updates…", target: self, action: #selector(updateClicked))
        updateButton.bezelStyle = .rounded
        let logsFolderButton = NSButton(title: "Open Logs Folder", target: self, action: #selector(logsClicked))
        logsFolderButton.bezelStyle = .rounded
        let footer = NSStackView(views: [diagnosticsButton, updateButton, logsFolderButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(footer)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: tab.topAnchor, constant: 8),
            headerStack.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: tab.trailingAnchor, constant: -20),

            controlRow.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            controlRow.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),

            vmHeader.topAnchor.constraint(equalTo: controlRow.bottomAnchor, constant: 12),
            vmHeader.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),

            vmScroll.topAnchor.constraint(equalTo: vmHeader.bottomAnchor, constant: 6),
            vmScroll.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),
            vmScroll.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -20),
            vmScroll.heightAnchor.constraint(equalTo: tab.heightAnchor, multiplier: 0.30),
            vmList.widthAnchor.constraint(equalTo: vmScroll.contentView.widthAnchor),

            jobsHeader.topAnchor.constraint(equalTo: vmScroll.bottomAnchor, constant: 10),
            jobsHeader.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),

            jobs.topAnchor.constraint(equalTo: jobsHeader.bottomAnchor, constant: 6),
            jobs.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 24),
            jobs.trailingAnchor.constraint(lessThanOrEqualTo: tab.trailingAnchor, constant: -20),

            footer.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),
            footer.bottomAnchor.constraint(equalTo: tab.bottomAnchor, constant: -14),
        ])
        return tab
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: Runtimes tab (embedded pane)

    private func buildRuntimesTab() -> NSView {
        let tab = NSView()
        tab.translatesAutoresizingMaskIntoConstraints = false
        let controller = RuntimesWindowController(embeddedIn: tab)
        controller.onEdited = { [weak self] in
            self?.runtimesEdited?()
        }
        self.runtimesController = controller
        return tab
    }

    // MARK: Tokens tab (embedded form)

    private func buildTokensTab() -> NSView {
        let tab = NSView()
        tab.translatesAutoresizingMaskIntoConstraints = false
        let controller = TokenSettingsWindowController(embeddedIn: tab)
        controller.onSaved = { [weak self] forge, token in
            try await self?.tokenSaved?(forge, token)
        }
        self.tokenController = controller
        return tab
    }

    // MARK: Logs tab (pretty viewer + search)

    private func buildLogsTab() -> NSView {
        let tab = NSView()
        tab.translatesAutoresizingMaskIntoConstraints = false
        let controller = LogsViewController()
        self.logsController = controller
        tab.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: tab.topAnchor, constant: 8),
            controller.view.bottomAnchor.constraint(equalTo: tab.bottomAnchor, constant: -14),
            controller.view.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),
            controller.view.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -20),
        ])
        return tab
    }

    // MARK: Settings tab

    private func buildSettingsTab() -> NSView {
        let tab = NSView()
        tab.translatesAutoresizingMaskIntoConstraints = false

        let card = LayerStyleView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.styleLayer = { layer in
            layer.cornerRadius = 10
            layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer.borderWidth = 1
            layer.borderColor = NSColor.separatorColor.cgColor
        }

        let header = NSTextField(labelWithString: "Settings")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        settingsSubtitle.font = .systemFont(ofSize: 11)
        settingsSubtitle.textColor = .secondaryLabelColor
        settingsSubtitle.maximumNumberOfLines = 2

        let modeLabel = NSTextField(labelWithString: "Show at launch")
        modeLabel.font = .systemFont(ofSize: 12)
        for mode in LaunchMode.allCases {
            modePopup.addItem(withTitle: mode.label)
            modePopup.lastItem?.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
        }
        modePopup.target = self
        modePopup.action = #selector(modePopupChanged)
        modePopup.setAccessibilityLabel("What kinhin shows at launch")

        let modeRow = NSStackView(views: [modeLabel, modePopup])
        modeRow.orientation = .horizontal
        modeRow.spacing = 10
        modeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        loginCheck.target = self
        loginCheck.action = #selector(loginToggled)
        loginCheck.font = .systemFont(ofSize: 12)
        loginCheck.setAccessibilityLabel("Launch kinhin at login")
        loginHint.font = .systemFont(ofSize: 10)
        loginHint.textColor = .tertiaryLabelColor

        let column = NSStackView(views: [header, settingsSubtitle, modeRow, loginCheck, loginHint])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            column.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -12),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -14),
            // The wrapping subtitle needs a bounded width or it collapses.
            settingsSubtitle.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        tab.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: tab.topAnchor, constant: 8),
            card.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -20),
        ])
        return tab
    }

    // MARK: Rendering

    /// Re-renders the Fleet tab's status line, controls, VM list, and
    /// current-jobs section. Safe to call before the first refresh.
    func render(status: FleetStatus?) {
        lastStatus = status
        statusLineLabel.stringValue = AppDelegate.statusLineText(for: status)
        isPaused = status?.paused ?? false
        pauseButton?.title = isPaused ? "Resume" : "Pause"

        if let vmStack {
            vmStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let records = status?.records ?? []
            if records.isEmpty {
                vmStack.addArrangedSubview(secondaryLabel("No VMs — the fleet is idle."))
            } else {
                for record in records {
                    vmStack.addArrangedSubview(makeVMRow(for: record))
                }
            }
        }

        if let jobsStack {
            jobsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let working = (status?.records ?? []).filter { $0.job != nil }
            guard !working.isEmpty else {
                jobsStack.addArrangedSubview(secondaryLabel("No jobs running."))
                return
            }
            for record in working {
                let repoText = (record.repos?.joined(separator: ", ") ?? "")
                let text = "▸ \(record.job ?? "") — \(repoText)  (\(record.id), \(record.phase.rawValue))"
                jobsStack.addArrangedSubview(secondaryLabel(text, mono: true))
            }
        }
    }

    private func secondaryLabel(_ text: String, mono: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = mono ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeVMRow(for record: VMRecord) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "• \(record.id) — \(record.phase.rawValue)")
        title.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        var parts: [String] = []
        if let repos = record.repos, !repos.isEmpty {
            parts.append(repos.count == 1 ? repos[0] : "\(repos.count) repos")
        }
        if let job = record.job { parts.append(job) }
        if let err = record.error { parts.append("⚠︎ \(err)") }
        let detail = NSTextField(labelWithString: parts.joined(separator: " · "))
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = record.error != nil ? .systemRed : .secondaryLabelColor

        let column = NSStackView(views: [title, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false

        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteVMClicked(_:)))
        delete.bezelStyle = .rounded
        delete.controlSize = .small
        delete.translatesAutoresizingMaskIntoConstraints = false
        delete.setAccessibilityLabel("Delete \(record.id)")
        delete.identifier = NSUserInterfaceItemIdentifier("deleteVM:\(record.id)")

        row.addSubview(column)
        row.addSubview(delete)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            column.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            column.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            delete.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            delete.leadingAnchor.constraint(greaterThanOrEqualTo: column.trailingAnchor, constant: 12),
            delete.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
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

    // MARK: Actions

    @objc private func startClicked() { delegate?.startFleet() }
    @objc private func stopClicked() { delegate?.stopFleet() }
    @objc private func pauseClicked() {
        if isPaused { delegate?.resumeFleet() } else { delegate?.pauseFleet() }
    }

    @objc private func deleteVMClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("deleteVM:") else { return }
        delegate?.deleteVM(id: String(id.dropFirst("deleteVM:".count)))
    }

    @objc private func logsClicked() { delegate?.openLogsFolder() }
    @objc private func updateClicked() { delegate?.checkForUpdatesNow() }

    @objc private func diagnosticsClicked() {
        guard let window else { return }
        if diagnosticsController == nil {
            let controller = DiagnosticsViewController()
            let sheet = NSWindow(contentViewController: controller)
            // Plain titled mask: fullSizeContentView draws the content
            // underneath the titlebar, hiding the sheet's header.
            sheet.styleMask = [.titled]
            sheet.title = "Diagnostics"
            diagnosticsWindow = sheet
            diagnosticsController = controller
        }
        window.beginSheet(diagnosticsWindow!) { _ in }
        Task { [diagnosticsController] in await diagnosticsController?.load() }
    }

    /// The diagnostics sheet's window (owned so the sheet can re-open).
    private var diagnosticsWindow: NSWindow?

    @objc private func modePopupChanged() {
        guard let raw = modePopup.selectedItem?.identifier?.rawValue,
              let mode = LaunchMode(rawValue: raw) else { return }
        Log.info("app", "launch mode set to \(mode.rawValue)")
        applyLaunchMode(mode)
    }

    @objc private func loginToggled() {
        let enabled = loginCheck.state == .on
        AppPreferences.setLaunchAtLogin(enabled, in: prefs)
        delegate?.launchAtLoginChanged(enabled)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        delegate?.mainTabsWindowWillClose()
    }
}
