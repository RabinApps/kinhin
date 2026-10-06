import AppKit
import Foundation
import KinhinKit
import SwiftUI

/// The models behind the main window's tabs, built on first use (a section's
/// model exists once it has been shown) and kept for the window's lifetime.
/// `MainTabsModel` decides when each is created and reloaded; the views only
/// render what exists.
@MainActor
final class WindowModels {
    let fleet: FleetController
    let updates: UpdateController
    /// Where the App section persists prefs. The real app uses .standard;
    /// tests inject a scratch suite.
    let prefs: UserDefaults

    /// App-level callbacks (launch mode, login item, logs folder, setup done).
    weak var delegate: MainTabsWindowDelegate?
    /// Config writes from Setup/Advanced must reach the engine/daemon.
    var runtimesEdited: (() -> Void)?
    /// Token saves persist to the Keychain and live-swap the engine token;
    /// the app injects the handler. Throws on Keychain/RPC failure so the
    /// form shows the error.
    var tokenSaved: ((ForgeID, String) async throws -> Void)?
    /// Same, for the named accounts of the Connect form's "More accounts".
    var accountTokenSaved: ((AccountConfig, String) async throws -> Void)?
    /// Whether a token is stored for a forge. The real Keychain by default;
    /// tests inject a stub so building the Accounts page never touches it.
    var tokenProbe: @Sendable (ForgeID) throws -> Bool = { try KeychainTokenStore.load(forge: $0) != nil }

    init(fleet: FleetController, updates: UpdateController, prefs: UserDefaults) {
        self.fleet = fleet
        self.updates = updates
        self.prefs = prefs
    }

    // MARK: - Tab models

    lazy var fleetModel: FleetModel = {
        let model = FleetModel(controller: fleet)
        return model
    }()

    lazy var appModel: AppSectionModel = {
        let model = AppSectionModel(prefs: prefs, updates: updates)
        model.onLaunchModeChanged = { [weak self] in self?.delegate?.launchModeChanged($0) }
        model.onLaunchAtLoginChanged = { [weak self] in self?.delegate?.launchAtLoginChanged($0) }
        model.onOpenLogs = { [weak self] in self?.delegate?.openLogsFolder() }
        model.onResetFinished = { [weak self] in self?.delegate?.resetFinished(scope: $0) }
        model.fleetController = fleet
        return model
    }()

    private(set) var wizardModel: WizardModel?
    private(set) var connectModel: ConnectModel?
    private(set) var macToolsModel: MacToolsModel?
    private(set) var capacityModel: CapacityModel?
    private(set) var containersModel: ContainersModel?
    private(set) var toolchainsModel: ToolchainsModel?
    private(set) var runtimesModel: RuntimesModel?
    private(set) var logsModel: LogsModel?
    private(set) var diagnosticsModel: DiagnosticsModel?
    private(set) var pipelineModel: PipelineModel?
    private(set) var workflowTestModel: WorkflowTestModel?
    private(set) var fleetDetailModel: FleetDetailModel?

    // MARK: - Setup wizard

    /// A fresh first-run wizard wired to the app's token handlers.
    func makeWizard(onFinished: @escaping () -> Void) -> WizardModel {
        let model = WizardModel()
        model.connect.saveToken = { [weak self] forge, token in
            try await self?.tokenSaved?(forge, token)
        }
        model.connect.accounts.saveToken = { [weak self] account, token in
            try await self?.accountTokenSaved?(account, token)
        }
        model.onFinished = onFinished
        wizardModel = model
        return model
    }

    func discardWizard() { wizardModel = nil }

    // MARK: - Advanced sections

    /// Builds a section's model on first use. Capacity, Routing and Accounts
    /// load once as they are built: `reloadSection` deliberately skips
    /// Capacity (a stale reload would discard unapplied edits), so a fresh
    /// model must fetch its own snapshot or the form renders blank forever.
    /// The Mac & VMs section (`.capacity`) also builds This Mac's model, so
    /// that section is self-contained; Accounts keeps only Connect.
    func ensureSection(_ section: AdvancedSection) {
        switch section {
        case .accounts:
            guard connectModel == nil else { return }
            let connect = ConnectModel()
            connect.saveToken = { [weak self] forge, token in
                try await self?.tokenSaved?(forge, token)
            }
            connect.accounts.saveToken = { [weak self] account, token in
                try await self?.accountTokenSaved?(account, token)
            }
            connect.hasStoredToken = tokenProbe
            connect.onChanged = { [weak self] in self?.runtimesEdited?() }
            connectModel = connect
            connect.reload()
        case .capacity:
            guard capacityModel == nil else { return }
            if macToolsModel == nil {
                let mac = MacToolsModel()
                mac.onChanged = { [weak self] in self?.runtimesEdited?() }
                macToolsModel = mac
                mac.reload()
            }
            let model = CapacityModel()
            model.configURL = Paths.config
            model.onChanged = { [weak self] in self?.runtimesEdited?() }
            capacityModel = model
            model.reload()
        case .routing:
            guard runtimesModel == nil else { return }
            let model = RuntimesModel()
            model.configURL = Paths.config
            model.onChanged = { [weak self] in self?.runtimesEdited?() }
            runtimesModel = model
            model.reload()
        case .containers:
            guard containersModel == nil else { return }
            containersModel = ContainersModel()
        case .toolchains:
            guard toolchainsModel == nil else { return }
            let model = ToolchainsModel()
            model.configURL = Paths.config
            toolchainsModel = model
            model.reload()
        case .app:
            _ = appModel
        }
    }

    /// Data-backed sections load when shown (Capacity's own form is skipped:
    /// reloading it would discard unapplied edits — its This Mac model does
    /// reload, it has nothing pending).
    func reloadSection(_ section: AdvancedSection) {
        switch section {
        case .routing: runtimesModel?.reload()
        case .containers: containersModel?.reload()
        case .accounts: connectModel?.reload()
        case .capacity:
            macToolsModel?.reload()
        case .toolchains: toolchainsModel?.reload()
        case .app: break
        }
    }

    // MARK: - Sheets

    func ensureLogsModel() -> LogsModel {
        if let logsModel { return logsModel }
        let model = LogsModel()
        logsModel = model
        return model
    }

    /// The pipeline sheet's model; one per opening, kept until the next so the
    /// sheet's view reads the same instance for as long as it is up.
    func makeWorkflowTestModel() -> WorkflowTestModel {
        let model = WorkflowTestModel(chooseFile: {
            await MainActor.run {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = [.yaml]
                return panel.runModal() == .OK ? panel.url : nil
            }
        })
        workflowTestModel = model
        return model
    }

    func makeFleetDetailModel() -> FleetDetailModel {
        let model = FleetDetailModel(controller: fleet)
        fleetDetailModel = model
        return model
    }

    func makePipelineModel(vmID: String) -> PipelineModel {
        let model = PipelineModel(vmID: vmID, controller: fleet)
        pipelineModel = model
        return model
    }

    func ensureDiagnosticsModel() -> DiagnosticsModel {
        if let diagnosticsModel { return diagnosticsModel }
        let model = DiagnosticsModel()
        model.fleetImageNotice = { [weak self] in self?.fleetModel.status?.imageNotice }
        diagnosticsModel = model
        return model
    }
}
