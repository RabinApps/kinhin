import AppKit
import KinhinKit
import SwiftUI

/// The first-run wizard: four short steps (Connect, This Mac, Select
/// toolchains, Start) that reuse the same forms as the Setup tab, so nothing
/// is entered in two different places.
///
/// A thin AppKit host: the steps and their state live in `WizardModel`, the
/// UI in `WizardView`.
@MainActor
final class OnboardingWizardViewController: NSViewController {
    typealias Step = WizardModel.Step

    let model = WizardModel()

    /// Fired when the user presses Start fleet.
    var onFinished: (() -> Void)? {
        get { model.onFinished }
        set { model.onFinished = newValue }
    }
    /// Fired when the user leaves setup unfinished ("Finish later").
    var onFinishLater: (() -> Void)? {
        get { model.onFinishLater }
        set { model.onFinishLater = newValue }
    }
    /// Persists a token and live-swaps it into a running engine (injected by
    /// the app; defaults to a Keychain save).
    var saveToken: ((ForgeID, String) async throws -> Void)? {
        didSet { if let saveToken { model.connect.saveToken = saveToken } }
    }

    /// Persists a named account's token and live-swaps it (injected by the app).
    var saveAccountToken: ((AccountConfig, String) async throws -> Void)? {
        didSet { if let saveAccountToken { model.connect.accounts.saveToken = saveAccountToken } }
    }

    var step: Step { model.step }

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("OnboardingWizardViewController is created in code") }

    override func loadView() {
        let host = NSHostingView(rootView: WizardView(model: model))
        // The wizard fills whatever it is pinned into; its content scrolls.
        host.sizingOptions = []
        view = host
        model.show(.connect)
    }

    // MARK: Test hooks

    func nextClickedForTesting() { model.next() }
    func skipClickedForTesting() { model.skip() }
    func backClickedForTesting() { model.back() }
    /// The wizard's forms are models; they expose the same settings the
    /// standalone form controllers do (`configURL`, `hasStoredToken`, …).
    var connectFormForTesting: ConnectModel { model.connect }
    var macFormForTesting: MacToolsModel { model.mac }
    var summaryTextForTesting: String { model.summaryText }
}
