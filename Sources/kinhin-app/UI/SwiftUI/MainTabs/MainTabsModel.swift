import KinhinKit
import Observation

/// A sheet over the main window.
enum MainSheet: Hashable, Identifiable {
    case logs
    case diagnostics
    /// The live pipeline of one VM.
    case pipeline(vmID: String)
    /// The workflow test sheet.
    case workflowTest
    /// The sponsor sheet (the star button's modal).
    case sponsor

    var id: String {
        switch self {
        case .logs: return "logs"
        case .diagnostics: return "diagnostics"
        case .pipeline(let vmID): return "pipeline:\(vmID)"
        case .workflowTest: return "workflow-test"
        case .sponsor: return "sponsor"
        }
    }
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
        models.fleetModel.onNeedsSetup = { [weak self] in self?.showSetup() }
        models.fleetModel.onShowLogs = { [weak self] in self?.present(.logs) }
        models.fleetModel.onShowDiagnostics = { [weak self] in self?.present(.diagnostics) }
        models.fleetModel.onShowPipeline = { [weak self] in self?.present(.pipeline(vmID: $0)) }
        models.fleetModel.onShowWorkflowTest = { [weak self] in self?.present(.workflowTest) }
        models.fleetModel.onShowBenchmarks = { [weak self] in self?.showAdvanced(.benchmarks) }
    }

    /// Set while first-run onboarding is up (or no usable config exists): the
    /// Setup tab then exists. Owned by `FleetController`.
    var setupIncomplete: Bool {
        get { fleet.setupIncomplete }
        set { fleet.setupIncomplete = newValue }
    }

    /// First-run setup is unfinished: the window shows only the wizard (no tab
    /// bar) and every other page, tab switch, menu action and sheet is
    /// unreachable until the wizard finishes.
    var isGatedBySetup: Bool { setupIncomplete }

    /// Tabs shown in the tab bar: none while setup gates the window.
    var visibleTabs: [MainTab] {
        isGatedBySetup ? [] : [.fleet, .advanced]
    }

    /// The tab on screen: the wizard while setup gates the window; afterwards
    /// a stale Setup request reads as Fleet.
    var selectedTab: MainTab {
        if isGatedBySetup { return .setup }
        return requestedTab == .setup ? .fleet : requestedTab
    }

    // MARK: - Navigation

    func select(_ tab: MainTab) {
        // While setup is unfinished every request lands on the wizard.
        if isGatedBySetup {
            requestedTab = .setup
            if models.wizardModel == nil { _ = makeWizard() }
            return
        }
        // Setup only exists during onboarding; afterwards its Connect form
        // lives in Advanced → Accounts (This Mac is under Capacity).
        if tab == .setup {
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
        guard !isGatedBySetup else {
            select(.setup)
            return
        }
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
        // Keep a wizard that is already up: re-opening Setup must not discard
        // what was typed into it (select builds one when none exists).
        select(.setup)
        Log.info("app", "guided setup shown")
    }

    /// While first-run setup is incomplete the window opens on the Setup tab.
    func applySetupInProgress() {
        if setupIncomplete { showSetup() }
    }

    /// Open config.yaml from the Setup wizard button row.
    func openConfig() {
        models.delegate?.openConfig()
    }

    /// Refreshes whichever section is visible (called when the window shows
    /// or the user lands on a tab via the menu). Probes and config reads
    /// never run from bare tab switches — tests stay hermetic.
    func refreshVisibleTab() {
        guard selectedTab == .advanced else { return }
        switch advancedSection {
        case .accounts:
            models.connectModel?.reload()
        case .capacity:
            // The capacity form never reloads on its own (unapplied edits),
            // but This Mac's model has nothing pending and refreshes.
            models.capacityModel?.reload()
            models.macToolsModel?.reload()
            models.runtimesModel?.reload()
        case .routing: models.runtimesModel?.reload()
        case .containers: models.containersModel?.reload()
        case .toolchains: models.toolchainsModel?.reload()
        case .benchmarks: models.benchmarksModel?.reload()
        case .app: break
        }
    }

    // MARK: - Setup wizard

    private func makeWizard() -> WizardModel {
        let wizard = models.makeWizard(
            onFinished: { [weak self] in
                // Setup is done: the tab bar appears and the window lands on Fleet.
                guard let self else { return }
                setupIncomplete = false
                models.discardWizard()
                requestedTab = .fleet
                onSetupFinished?()
            })
        wizard.openConfig = { [weak self] in self?.openConfig() }
        return wizard
    }

    // MARK: - Sheets

    /// Ignored while setup gates the window: the sheets stay hidden.
    func present(_ sheet: MainSheet) {
        guard !isGatedBySetup else { return }
        switch sheet {
        case .logs:
            models.ensureLogsModel().refresh()
        case .diagnostics:
            let model = models.ensureDiagnosticsModel()
            Task { await model.load() }
        case .pipeline(let vmID):
            // A fresh model per opening: it starts on the job list, not on
            // whatever job the last sheet had drilled into.
            let model = models.makePipelineModel(vmID: vmID)
            Task { await model.load() }
        case .workflowTest:
            // A fresh model per opening: it starts on the job list, not on
            // whatever job the last sheet had drilled into.
            _ = models.makeWorkflowTestModel()
        case .sponsor:
            break  // static content; no model to prepare
        }
        self.sheet = sheet
    }

    func dismissSheet() { sheet = nil }

    private var wizardModel: WizardModel? { models.wizardModel }
}
