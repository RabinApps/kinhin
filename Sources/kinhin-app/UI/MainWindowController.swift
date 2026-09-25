import AppKit
import KinhinKit

// MARK: - Main tabs window

/// kinhin's single main window: a segmented control switches between Fleet,
/// Setup, and Advanced. Setup shows a guided wizard until first-run setup is
/// complete, then the same forms as an editable page.
@MainActor
final class MainTabsWindowController: NSWindowController, NSWindowDelegate {
    weak var delegate: MainTabsWindowDelegate?

    // Tab surfaces (created lazily on first selection).
    var tabViews: [MainTab: NSView] = [:]

    // Header
    /// The tab bar. Its segments are rebuilt by `rebuildTabBar()`: the Setup
    /// tab only exists while first-run setup is unfinished.
    let segmentControl = NSSegmentedControl(
        labels: [],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    let tabContentContainer = NSView()

    // Embedded child controllers (created once with their tabs).
    var wizardController: OnboardingWizardViewController?
    var connectController: ConnectFormViewController?
    var macToolsController: MacToolsFormViewController?
    var configController: ConfigTabViewController?
    var containersController: ContainersViewController?
    var toolchainsController: ToolchainsViewController?
    var runtimesController: RuntimesWindowController?
    var logsController: LogsViewController?
    var diagnosticsController: DiagnosticsViewController?
    /// Config writes from Setup/Advanced must reach the engine/daemon; the
    /// app injects the same handler the standalone pane used.
    var runtimesEdited: (() -> Void)?
    /// Token saves persist to the Keychain and live-swap the engine token;
    /// the app injects the handler. Throws on Keychain/RPC failure so the
    /// form shows the error.
    var tokenSaved: ((ForgeID, String) async throws -> Void)?

    // Fleet tab controls
    let statusLineLabel = NSTextField(wrappingLabelWithString: "Loading…")
    var isPaused = false
    var pauseButton: NSButton?
    var vmStack: NSStackView?
    var jobsStack: NSStackView?

    // Advanced tab
    let advancedSegments = NSSegmentedControl(
        labels: AdvancedSection.allCases.map(\.label),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    let advancedContainer = NSView()
    var advancedViews: [AdvancedSection: NSView] = [:]
    var selectedAdvancedSection: AdvancedSection = .accounts

    // App section controls
    let settingsSubtitle = NSTextField(wrappingLabelWithString: "")
    let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let loginCheck = NSButton(checkboxWithTitle: "Launch kinhin at login", target: nil, action: nil)
    let loginHint = NSTextField(
        wrappingLabelWithString:
            "Applies to the installed kinhin.app — no effect while running unbundled from `swift run`.")
    /// Where the App section persists prefs. The real app uses .standard;
    /// tests inject a scratch suite.
    var prefs: UserDefaults = .standard

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
        window.appearance = nil  // follow the system (light & dark)
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

    /// The logs sheet currently shown, if any.
    var logsSheet: NSWindow?

    /// The diagnostics sheet's window (owned so the sheet can re-open).
    var diagnosticsWindow: NSWindow?

    // MARK: UI construction

    func buildUI(in container: NSView) {
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

    var selectedTab: MainTab = .fleet

    /// Tabs currently shown: Setup appears only until first-run setup is done.
    var visibleTabs: [MainTab] {
        setupIncompleteFlag ? [.fleet, .setup, .advanced] : [.fleet, .advanced]
    }

    func rebuildTabBar() {
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

    func pin(_ view: NSView, in container: NSView) {
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
    func installTab(_ tab: MainTab) -> NSView? {
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

    @objc func segmentChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        let tabs = visibleTabs
        guard tabs.indices.contains(index) else { return }
        Log.info("app", "tab → \(tabs[index].rawValue)")
        selectTab(tabs[index])
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        delegate?.mainTabsWindowWillClose()
    }
}
