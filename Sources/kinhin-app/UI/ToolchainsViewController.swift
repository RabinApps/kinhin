import AppKit
import KinhinKit
import SwiftUI

/// Advanced → Toolchains: choose what gets preinstalled into your runner
/// images, and rebuild the images with it. Also the setup wizard's toolchains
/// step (`seed: .allOff`, where the user explicitly picks everything).
///
/// A thin AppKit host: state and actions live in `ToolchainsModel`, the UI in
/// `ToolchainsView`.
@MainActor
final class ToolchainsViewController: NSViewController {
    typealias Seed = ToolchainsModel.Seed

    let model: ToolchainsModel

    init(seed: Seed = .fromConfig) {
        model = ToolchainsModel(seed: seed)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("created in code") }

    override func loadView() {
        view = NSHostingView(rootView: ToolchainsView(model: model))
        reload()
    }

    // MARK: Forwarding (the wizard, Advanced page, and tests use these)

    var seed: Seed { model.seed }
    var configURL: URL {
        get { model.configURL }
        set { model.configURL = newValue }
    }
    var onEdited: (() -> Void)? {
        get { model.onEdited }
        set { model.onEdited = newValue }
    }
    var confirmRebuild: (_ runtime: RuntimeID, _ plan: ToolchainsConfigEditor.Plan) -> Bool {
        get { model.confirmRebuild }
        set { model.confirmRebuild = newValue }
    }
    var rebuild: (_ runtime: RuntimeID, _ config: KinhinConfig) async throws -> Void {
        get { model.rebuild }
        set { model.rebuild = newValue }
    }
    var baseline: ToolchainsSelection { model.baseline }
    var working: ToolchainsSelection { model.working }
    var hasPendingChanges: Bool { model.hasPendingChanges }

    func reload() { model.reload() }
    func apply() { model.apply() }

    @discardableResult
    func startRebuild(_ runtime: RuntimeID) -> Task<Void, Never>? { model.startRebuild(runtime) }
}
