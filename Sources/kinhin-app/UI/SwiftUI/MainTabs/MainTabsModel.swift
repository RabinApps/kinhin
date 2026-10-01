import KinhinKit
import Observation

/// A sheet over the main window.
enum MainSheet: String, Identifiable {
    case logs
    case diagnostics

    var id: String { rawValue }
}

/// Which tab, Advanced section and sheet the main window shows. The pure
/// navigation rules live here (tab order, the Setup tab's lifetime,
/// Setup → Accounts redirect); `MainTabsView` renders them.
@MainActor
@Observable
final class MainTabsModel {
    @ObservationIgnored let fleet: FleetController
    @ObservationIgnored let models: WindowModels
    /// Setup finished (its Start Fleet was pressed): the app re-bootstraps.
    @ObservationIgnored var onSetupFinished: (() -> Void)?

    private var requestedTab: MainTab = .fleet
    private(set) var advancedSection: AdvancedSection = .accounts
    var sheet: MainSheet?
    /// The Advanced tab has been opened once (its first section is built then).
    @ObservationIgnored private var advancedInstalled = false

    init(fleet: FleetController, models: WindowModels) {
        self.fleet = fleet
        self.models = models
        models.fleetModel.onShowLogs = { [weak self] in self?.present(.logs) }
        models.fleetModel.onShowDiagnostics = { [weak self] in self?.present(.diagnostics) }
    }

    /// Set while first-run onboarding is up (or no usable config exists): the
    /// Setup tab then exists. Owned by `FleetController`.
    var setupIncomplete: Bool {
        get { fleet.setupIncomplete }
        set { fleet.setupIncomplete = newValue }
    }

    /// Tabs currently shown: Setup appears only until first-run setup is done.
    var visibleTabs: [MainTab] {
        setupIncomplete ? [.fleet, .setup, .advanced] : [.fleet, .advanced]
    }

    /// The tab on screen; a vanished Setup tab reads as Fleet.
    var selectedTab: MainTab {
        requestedTab == .setup && !setupIncomplete ? .fleet : requestedTab
    }

    // MARK: - Navigation

    func select(_ tab: MainTab) {
        // Setup only exists during onboarding; afterwards its forms live in
        // Advanced → Accounts.
        if tab == .setup && !setupIncomplete {
            showAdvanced(.accounts)
            return
        }
        requestedTab = tab
        switch tab {
        case .setup:
            if models.wizardModel == nil { _ = makeWizard() }
        case .advanced:
            // The first visit builds (and loads) the current section; later
            // tab switches never re-probe.
            if !advancedInstalled {
                advancedInstalled = true
                selectAdvancedSection(advancedSection)
            }
        case .fleet:
            break
        }
    }

    /// A click on the tab bar.
    func userSelected(_ tab: MainTab) {
        Log.info("app", "tab → \(tab.rawValue)")
        select(tab)
    }

    func selectAdvancedSection(_ section: AdvancedSection) {
        advancedSection = section
        models.ensureSection(section)
        models.reloadSection(section)
    }

    /// Opens Advanced on a given section (used by the menu).
    func showAdvanced(_ section: AdvancedSection) {
        select(.advanced)
        selectAdvancedSection(section)
    }

    /// Opens setup: the guided wizard while setup is unfinished, otherwise the
    /// Accounts section of Advanced (there is no Setup tab after onboarding).
    func showSetup() {
        guard setupIncomplete else {
            showAdvanced(.accounts)
            return
        }
        _ = makeWizard()
        select(.setup)
        Log.info("app", "guided setup shown")
    }

    /// While first-run setup is incomplete the window opens on the Setup tab.
    func applySetupInProgress() {
        if setupIncomplete { showSetup() }
    }

    /// Refreshes whichever section is visible (called when the window shows
    /// or the user lands on a tab via the menu). Probes and config reads
    /// never run from bare tab switches — tests stay hermetic.
    func refreshVisibleTab() {
        guard selectedTab == .advanced else { return }
        switch advancedSection {
        case .accounts:
            models.connectModel?.reload()
            models.macToolsModel?.reload()
        case .capacity: models.capacityModel?.reload()
        case .routing: models.runtimesModel?.reload()
        case .containers: models.containersModel?.reload()
        case .toolchains, .app: break
        }
    }

    // MARK: - Setup wizard

    private func makeWizard() -> WizardModel {
        models.makeWizard(
            onFinished: { [weak self] in
                // Setup is done: the Setup tab goes away for good.
                guard let self else { return }
                setupIncomplete = false
                models.discardWizard()
                requestedTab = .fleet
                onSetupFinished?()
            },
            onFinishLater: { [weak self] in
                // Leave setup as it is; the Setup tab stays until it is finished.
                self?.requestedTab = .fleet
            })
    }

    // MARK: - Sheets

    func present(_ sheet: MainSheet) {
        switch sheet {
        case .logs:
            models.ensureLogsModel().refresh()
        case .diagnostics:
            let model = models.ensureDiagnosticsModel()
            Task { await model.load() }
        }
        self.sheet = sheet
    }

    func dismissSheet() { sheet = nil }
}
