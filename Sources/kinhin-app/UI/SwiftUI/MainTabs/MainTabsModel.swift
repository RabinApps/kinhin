import KinhinKit
import Observation

/// A sheet over the main window. Logs and Diagnostics are not sheets any more: they are panes of the Diagnostics
/// section.
enum MainSheet: Hashable, Identifiable {
    /// The live pipeline of one VM.
    case pipeline(vmID: String)
    /// The workflow test sheet.
    case workflowTest
    /// Make a video of a repository (`kinhin video`), and find music for it.
    case videos
    /// The sponsor sheet (the sidebar's "Support kinhin").
    case sponsor

    var id: String {
        switch self {
        case .pipeline(let vmID): return "pipeline:\(vmID)"
        case .workflowTest: return "workflow-test"
        case .videos: return "videos"
        case .sponsor: return "sponsor"
        }
    }
}

/// Which section, Diagnostics pane and sheet the main window shows. The pure navigation rules live here (the sidebar's
/// sections, the first-run Setup gate, the Setup → Accounts redirect, the Diagnostics panes); `MainShellView`
/// renders them.
@MainActor
@Observable
final class MainTabsModel {
    @ObservationIgnored let fleet: FleetController
    @ObservationIgnored let models: WindowModels
    /// Setup finished (its Start Fleet was pressed): the app re-bootstraps.
    @ObservationIgnored var onSetupFinished: (() -> Void)?

    private var requestedSection: MainSection = .fleet
    private(set) var diagnosticsPane: DiagnosticsPane = .health
    var sheet: MainSheet?
    /// The sidebar is folded to its icon rail. Persisted across launches.
    private(set) var sidebarCollapsed: Bool

    init(fleet: FleetController, models: WindowModels) {
        self.fleet = fleet
        self.models = models
        sidebarCollapsed = models.prefs.bool(forKey: Self.sidebarCollapsedKey)
        models.fleetModel.onNeedsSetup = { [weak self] in self?.showSetup() }
        models.fleetModel.onShowLogs = { [weak self] in self?.showDiagnostics(.logs) }
        models.fleetModel.onShowDiagnostics = { [weak self] in self?.showDiagnostics(.health) }
        models.fleetModel.onShowPipeline = { [weak self] in self?.present(.pipeline(vmID: $0)) }
        models.fleetModel.onShowWorkflowTest = { [weak self] in self?.present(.workflowTest) }
        models.fleetModel.onShowVideos = { [weak self] in self?.present(.videos) }
        models.fleetModel.onShowBenchmarks = { [weak self] in self?.showDiagnostics(.benchmarks) }
    }

    /// Set while first-run onboarding is up (or no usable config exists): the
    /// wizard then owns the window. Owned by `FleetController`.
    var setupIncomplete: Bool {
        get { fleet.setupIncomplete }
        set { fleet.setupIncomplete = newValue }
    }

    /// First-run setup is unfinished: the window shows only the wizard (no
    /// sidebar) and every other section, menu action and sheet is
    /// unreachable until the wizard finishes.
    var isGatedBySetup: Bool { setupIncomplete }

    /// Sections shown in the sidebar: none while setup gates the window.
    var visibleSections: [MainSection] {
        isGatedBySetup ? [] : MainSection.allCases
    }

    /// The section on screen. While setup gates the window the wizard is shown instead (`isGatedBySetup`), whatever
    /// this says; finishing the wizard lands on Fleet.
    var selectedSection: MainSection { requestedSection }

    // MARK: - Navigation

    /// Opens a section, building its model on the first visit and reloading data-backed ones on every visit.
    /// While setup is unfinished every request lands on the wizard.
    func select(_ section: MainSection) {
        guard !isGatedBySetup else {
            if models.wizardModel == nil { _ = makeWizard() }
            return
        }
        requestedSection = section
        models.ensureSection(section, pane: diagnosticsPane)
        models.reloadSection(section, pane: diagnosticsPane)
        if section == .diagnostics { probeHealthIfShown() }
    }

    /// A click on the sidebar.
    func userSelected(_ section: MainSection) {
        Log.info("app", "section → \(section.rawValue)")
        select(section)
    }

    /// Opens Diagnostics on one of its panes (the Fleet screen's Logs and Benchmarks buttons, the menu's Open Logs).
    func showDiagnostics(_ pane: DiagnosticsPane = .health) {
        guard !isGatedBySetup else {
            select(.diagnostics)
            return
        }
        diagnosticsPane = pane
        select(.diagnostics)
    }

    /// A click on the Diagnostics segmented control.
    func selectDiagnosticsPane(_ pane: DiagnosticsPane) {
        guard !isGatedBySetup else { return }
        diagnosticsPane = pane
        models.ensureDiagnosticsPane(pane)
        models.reloadDiagnosticsPane(pane)
        probeHealthIfShown()
    }

    /// Opens Settings (the app menu's and the status menu's "Settings…").
    func showSettings() { select(.settings) }

    /// Opens setup: the guided wizard while setup is unfinished, otherwise the
    /// Accounts section (there is no Setup page after onboarding).
    func showSetup() {
        guard setupIncomplete else {
            select(.accounts)
            return
        }
        // Keep a wizard that is already up: re-opening Setup must not discard
        // what was typed into it.
        if models.wizardModel == nil { _ = makeWizard() }
        Log.info("app", "guided setup shown")
    }

    /// While first-run setup is incomplete the window opens on the wizard.
    func applySetupInProgress() {
        if setupIncomplete { showSetup() }
    }

    /// Open config.yaml from the Setup wizard button row.
    func openConfig() {
        models.delegate?.openConfig()
    }

    /// Refreshes whichever section is visible (called when the window shows
    /// or the user lands on it via the menu). Probes and config reads
    /// never run from bare section switches — tests stay hermetic — and the
    /// health probe never runs from a refresh at all.
    func refreshVisibleSection() {
        guard !isGatedBySetup else { return }
        switch selectedSection {
        case .fleet, .settings: break
        case .accounts:
            models.connectModel?.reload()
        case .runtimes:
            // The capacity form never reloads on its own (unapplied edits),
            // but This Mac's model has nothing pending and refreshes.
            models.capacityModel?.reload()
            models.macToolsModel?.reload()
            models.runtimesModel?.reload()
        case .toolchains: models.toolchainsModel?.reload()
        case .diagnostics: models.reloadDiagnosticsPane(diagnosticsPane)
        }
    }

    // MARK: - Sidebar

    static let sidebarCollapsedKey = "advancedSidebarCollapsed"

    func toggleSidebar() {
        sidebarCollapsed.toggle()
        models.prefs.set(sidebarCollapsed, forKey: Self.sidebarCollapsedKey)
    }

    // MARK: - Health probe

    /// The health report runs its probes when its pane is opened (the page says "probes run when you open
    /// Diagnostics"), not on every refresh.
    private func probeHealthIfShown() {
        guard selectedSection == .diagnostics, diagnosticsPane == .health else { return }
        let model = models.ensureDiagnosticsModel()
        Task { await model.load() }
    }

    // MARK: - Setup wizard

    private func makeWizard() -> WizardModel {
        let wizard = models.makeWizard(
            onFinished: { [weak self] in
                // Setup is done: the sidebar appears and the window lands on Fleet.
                guard let self else { return }
                setupIncomplete = false
                models.discardWizard()
                requestedSection = .fleet
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
        case .pipeline(let vmID):
            // A fresh model per opening: it starts on the job list, not on
            // whatever job the last sheet had drilled into.
            let model = models.makePipelineModel(vmID: vmID)
            Task { await model.load() }
        case .workflowTest:
            // A fresh model per opening: it starts on the job list, not on
            // whatever job the last sheet had drilled into.
            _ = models.makeWorkflowTestModel()
        case .videos:
            _ = models.ensureVideosModel()
        case .sponsor:
            break  // static content; no model to prepare
        }
        self.sheet = sheet
    }

    func dismissSheet() { sheet = nil }
}
