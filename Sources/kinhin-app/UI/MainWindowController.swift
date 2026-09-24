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

/// The main window's tabs. Fleet is the day-to-day view, Setup is where an
/// account and this Mac are connected (a guided wizard on first run), and
/// Advanced holds everything you rarely touch.
enum MainTab: String, CaseIterable {
    case fleet
    case setup
    case advanced

    var label: String {
        switch self {
        case .fleet: return "Fleet"
        case .setup: return "Setup"
        case .advanced: return "Advanced"
        }
    }
}

/// Sub-sections of the Advanced tab.
enum AdvancedSection: String, CaseIterable {
    case accounts
    case capacity
    case routing
    case containers
    case toolchains
    case app

    var label: String {
        switch self {
        case .accounts: return "Accounts"
        case .capacity: return "Capacity"
        case .routing: return "Routing"
        case .containers: return "Containers"
        case .toolchains: return "Toolchains"
        case .app: return "App"
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
/// Setup, and Advanced. Setup shows a guided wizard until first-run setup is
/// complete, then the same forms as an editable page.
@MainActor
final class MainTabsWindowController: NSWindowController, NSWindowDelegate {
    weak var delegate: MainTabsWindowDelegate?

    // Tab surfaces (created lazily on first selection).
    private var tabViews: [MainTab: NSView] = [:]

    // Header
    /// The tab bar. Its segments are rebuilt by `rebuildTabBar()`: the Setup
    /// tab only exists while first-run setup is unfinished.
    private let segmentControl = NSSegmentedControl(
        labels: [],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let tabContentContainer = NSView()

    // Embedded child controllers (created once with their tabs).
    private(set) var wizardController: OnboardingWizardViewController?
    private(set) var connectController: ConnectFormViewController?
    private(set) var macToolsController: MacToolsFormViewController?
    private(set) var configController: ConfigTabViewController?
    private(set) var containersController: ContainersViewController?
    private(set) var toolchainsController: ToolchainsViewController?
    private(set) var runtimesController: RuntimesWindowController?
    private(set) var logsController: LogsViewController?
    private(set) var diagnosticsController: DiagnosticsViewController?
    /// Config writes from Setup/Advanced must reach the engine/daemon; the
    /// app injects the same handler the standalone pane used.
    var runtimesEdited: (() -> Void)?
    /// Token saves persist to the Keychain and live-swap the engine token;
    /// the app injects the handler. Throws on Keychain/RPC failure so the
    /// form shows the error.
    var tokenSaved: ((ForgeID, String) async throws -> Void)?

    // Fleet tab controls
    private let statusLineLabel = NSTextField(wrappingLabelWithString: "Loading…")
    private var isPaused = false
    private var pauseButton: NSButton?
    private var vmStack: NSStackView?
    private var jobsStack: NSStackView?

    // Advanced tab
    private let advancedSegments = NSSegmentedControl(
        labels: AdvancedSection.allCases.map(\.label),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let advancedContainer = NSView()
    private var advancedViews: [AdvancedSection: NSView] = [:]
    private(set) var selectedAdvancedSection: AdvancedSection = .accounts

    // App section controls
    private let settingsSubtitle = NSTextField(wrappingLabelWithString: "")
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loginCheck = NSButton(checkboxWithTitle: "Launch kinhin at login", target: nil, action: nil)
    private let loginHint = NSTextField(wrappingLabelWithString: "Applies to the installed kinhin.app — no effect while running unbundled from `swift run`.")
    /// Where the App section persists prefs. The real app uses .standard;
    /// tests inject a scratch suite.
    private var prefs: UserDefaults = .standard

    /// Latest fleet status, so a reopened window renders live data instantly.
    var lastStatus: FleetStatus?

    convenience init() {
        self.init(defaults: .standard)
    }

    convenience init(defaults: UserDefaults) {
        let size = NSSize(width: 620, height: 600)
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
        window.minSize = NSSize(width: 620, height: 480)
        self.init(window: window)
        prefs = defaults
        window.delegate = self
        buildUI(in: container)
        // Tabs install themselves on selection (their views must be in the
        // hierarchy before constraints pin them to the container).
        rebuildTabBar()
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
        segmentControl.segmentDistribution = .fillEqually
        segmentControl.translatesAutoresizingMaskIntoConstraints = false
        segmentControl.setAccessibilityLabel("kinhin sections")

        tabContentContainer.wantsLayer = true
        tabContentContainer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(segmentControl)
        container.addSubview(tabContentContainer)

        NSLayoutConstraint.activate([
            segmentControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            segmentControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            segmentControl.widthAnchor.constraint(equalToConstant: 300),

            tabContentContainer.topAnchor.constraint(equalTo: segmentControl.bottomAnchor, constant: 14),
            tabContentContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabContentContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabContentContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Tabs build lazily on first selection (installTab) so their views
        // are only pinned once they share the container's hierarchy.
    }

    // MARK: Tab switching

    private(set) var selectedTab: MainTab = .fleet

    /// Tabs currently shown: Setup appears only until first-run setup is done.
    var visibleTabs: [MainTab] {
        setupIncompleteFlag ? [.fleet, .setup, .advanced] : [.fleet, .advanced]
    }

    private func rebuildTabBar() {
        let tabs = visibleTabs
        segmentControl.segmentCount = tabs.count
        for (index, tab) in tabs.enumerated() {
            segmentControl.setLabel(tab.label, forSegment: index)
        }
        segmentControl.selectedSegment = tabs.firstIndex(of: selectedTab) ?? 0
    }

    func selectTab(_ tab: MainTab, notify: Bool = true) {
        // Setup only exists during onboarding; afterwards its forms live in
        // Advanced → Accounts.
        if tab == .setup && !setupIncompleteFlag {
            showAdvanced(.accounts)
            return
        }
        selectedTab = tab
        segmentControl.selectedSegment = visibleTabs.firstIndex(of: tab) ?? 0
        tabContentContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let view = tabViews[tab] ?? installTab(tab) else { return }
        pin(view, in: tabContentContainer)
    }

    private func pin(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    /// Creates a tab's view on first selection.
    private func installTab(_ tab: MainTab) -> NSView? {
        let view: NSView
        switch tab {
        case .fleet: view = buildFleetTab()
        case .setup: view = buildSetupTab()
        case .advanced: view = buildAdvancedTab()
        }
        tabViews[tab] = view
        return view
    }

    /// Refreshes whichever tab is visible (called when the window shows or
    /// the user lands on a tab via the menu). Probes and config reads never
    /// run from bare tab switches — tests stay hermetic.
    func refreshVisibleTab() {
        switch selectedTab {
        case .fleet:
            Task { [diagnosticsController] in await diagnosticsController?.refreshIfVisible() }
        case .setup:
            break
        case .advanced:
            switch selectedAdvancedSection {
            case .accounts:
                connectController?.reload()
                macToolsController?.reload()
            case .capacity: configController?.reload()
            case .routing: runtimesController?.reload()
            case .containers: containersController?.reload()
            case .toolchains: break
            case .app: break
            }
        }
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        let tabs = visibleTabs
        guard tabs.indices.contains(index) else { return }
        Log.info("app", "tab → \(tabs[index].rawValue)")
        selectTab(tabs[index])
    }

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

    /// Whether a token is stored for a forge. The real Keychain by default;
    /// tests inject a stub so building the Accounts page never touches it.
    var tokenProbe: @Sendable (ForgeID) -> Bool = { KeychainTokenStore.load(forge: $0) != nil }

    /// Set by the app delegate before the window opens. Adds/removes the
    /// Setup tab.
    var setupIncompleteFlag = false {
        didSet {
            guard setupIncompleteFlag != oldValue else { return }
            rebuildTabBar()
        }
    }

    /// The first-run wizard (the only content of the Setup tab).
    private func buildSetupTab() -> NSView {
        let tab = NSView()
        tab.translatesAutoresizingMaskIntoConstraints = false
        let wizard = OnboardingWizardViewController()
        wizard.saveToken = { [weak self] forge, token in
            try await self?.tokenSaved?(forge, token)
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
    private func buildAccountsSection() -> NSView {
        let tab = NSView()
        let connect = ConnectFormViewController()
        connect.saveToken = { [weak self] forge, token in
            try await self?.tokenSaved?(forge, token)
        }
        connect.hasStoredToken = tokenProbe
        connect.onChanged = { [weak self] in self?.runtimesEdited?() }
        let mac = MacToolsFormViewController()
        mac.onChanged = { [weak self] in self?.runtimesEdited?() }
        connectController = connect
        macToolsController = mac

        let (scroll, column) = FormKit.scrollingColumn(spacing: 14)
        column.addArrangedSubview(sectionHeader("Connect"))
        column.addArrangedSubview(connect.view)
        column.addArrangedSubview(sectionHeader("This Mac"))
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
        // Flipped document so rows start at the TOP of the scroll area (an
        // unflipped one floats short lists to the bottom).
        let vmDocument = FlippedView()
        vmDocument.translatesAutoresizingMaskIntoConstraints = false
        vmDocument.addSubview(vmList)
        vmScroll.documentView = vmDocument
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
        let logsButton = NSButton(title: "Logs…", target: self, action: #selector(showLogsClicked))
        logsButton.bezelStyle = .rounded
        let footer = NSStackView(views: [logsButton, diagnosticsButton, updateButton])
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
            vmDocument.topAnchor.constraint(equalTo: vmScroll.contentView.topAnchor),
            vmDocument.leadingAnchor.constraint(equalTo: vmScroll.contentView.leadingAnchor),
            vmDocument.trailingAnchor.constraint(equalTo: vmScroll.contentView.trailingAnchor),
            vmList.topAnchor.constraint(equalTo: vmDocument.topAnchor),
            vmList.leadingAnchor.constraint(equalTo: vmDocument.leadingAnchor),
            vmList.trailingAnchor.constraint(equalTo: vmDocument.trailingAnchor),
            vmList.bottomAnchor.constraint(equalTo: vmDocument.bottomAnchor),

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

    // MARK: Advanced tab

    private func buildAdvancedTab() -> NSView {
        let tab = NSView()
        tab.translatesAutoresizingMaskIntoConstraints = false

        advancedSegments.target = self
        advancedSegments.action = #selector(advancedSegmentChanged(_:))
        advancedSegments.controlSize = .small
        advancedSegments.translatesAutoresizingMaskIntoConstraints = false
        advancedSegments.setAccessibilityLabel("Advanced sections")
        advancedContainer.translatesAutoresizingMaskIntoConstraints = false

        tab.addSubview(advancedSegments)
        tab.addSubview(advancedContainer)
        NSLayoutConstraint.activate([
            advancedSegments.topAnchor.constraint(equalTo: tab.topAnchor),
            advancedSegments.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 20),
            advancedSegments.widthAnchor.constraint(equalToConstant: 560),

            advancedContainer.topAnchor.constraint(equalTo: advancedSegments.bottomAnchor, constant: 12),
            advancedContainer.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 16),
            advancedContainer.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -16),
            advancedContainer.bottomAnchor.constraint(equalTo: tab.bottomAnchor, constant: -12),
        ])
        selectAdvancedSection(selectedAdvancedSection)
        return tab
    }

    func selectAdvancedSection(_ section: AdvancedSection) {
        selectedAdvancedSection = section
        advancedSegments.selectedSegment = AdvancedSection.allCases.firstIndex(of: section) ?? 0
        advancedContainer.subviews.forEach { $0.removeFromSuperview() }
        let view = advancedViews[section] ?? {
            let built: NSView
            switch section {
            case .accounts: built = buildAccountsSection()
            case .capacity: built = buildCapacitySection()
            case .routing: built = buildRoutingSection()
            case .containers: built = buildContainersSection()
            case .toolchains: built = buildToolchainsSection()
            case .app: built = buildAppSection()
            }
            advancedViews[section] = built
            return built
        }()
        pin(view, in: advancedContainer)
        // Data-backed sections load when shown (Capacity is skipped: reloading
        // it would discard unapplied edits).
        switch section {
        case .routing: runtimesController?.reload()
        case .containers: containersController?.reload()
        case .toolchains: break
        case .accounts:
            connectController?.reload()
            macToolsController?.reload()
        case .capacity, .app: break
        }
    }

    @objc private func advancedSegmentChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard AdvancedSection.allCases.indices.contains(index) else { return }
        selectAdvancedSection(AdvancedSection.allCases[index])
    }

    /// Opens Advanced on a given section (used by the menu).
    func showAdvanced(_ section: AdvancedSection) {
        selectTab(.advanced)
        selectAdvancedSection(section)
    }

    private func buildCapacitySection() -> NSView {
        let controller = ConfigTabViewController()
        controller.onEdited = { [weak self] in self?.runtimesEdited?() }
        configController = controller
        return controller.view
    }

    private func buildToolchainsSection() -> NSView {
        let controller = ToolchainsViewController()
        controller.onEdited = { [weak self] in self?.runtimesEdited?() }
        toolchainsController = controller
        return controller.view
    }

    private func buildContainersSection() -> NSView {
        let controller = ContainersViewController()
        containersController = controller
        return controller.view
    }

    private func buildRoutingSection() -> NSView {
        let tab = NSView()
        let controller = RuntimesWindowController(embeddedIn: tab)
        controller.onEdited = { [weak self] in self?.runtimesEdited?() }
        runtimesController = controller
        return tab
    }

    // MARK: App section (launch behavior, files)

    private func buildAppSection() -> NSView {
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

    @objc private func openConfigFileClicked() {
        NSWorkspace.shared.open(Paths.config)
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

    /// Logs open as a sheet from the Fleet tab (they are a debugging aid, not
    /// a day-to-day destination).
    @objc private func showLogsClicked() {
        guard let window else { return }
        if logsSheet == nil {
            let controller = LogsViewController()
            logsController = controller
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            sheet.title = "Logs"
            let content = NSView(frame: sheet.contentRect(forFrameRect: sheet.frame))
            sheet.contentView = content
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            let close = NSButton(title: "Done", target: self, action: #selector(closeLogsSheet))
            close.bezelStyle = .rounded
            close.keyEquivalent = "\r"
            let folder = NSButton(title: "Open logs folder", target: self, action: #selector(logsClicked))
            folder.bezelStyle = .rounded
            let buttons = NSStackView(views: [folder, NSView(), close])
            buttons.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(controller.view)
            content.addSubview(buttons)
            NSLayoutConstraint.activate([
                controller.view.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                controller.view.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
                buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            ])
            sheet.minSize = NSSize(width: 480, height: 320)
            logsSheet = sheet
        }
        window.beginSheet(logsSheet!) { _ in }
        logsController?.refreshNow()
    }

    @objc private func closeLogsSheet() {
        guard let sheet = logsSheet else { return }
        window?.endSheet(sheet)
    }

    private var logsSheet: NSWindow?

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
