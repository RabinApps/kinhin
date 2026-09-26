import AppKit
import KinhinKit
import SwiftUI

/// The one place an account is connected: a GitHub card (token → repo or org)
/// and an optional self-hosted Gitea card. Used by both the onboarding
/// wizard and the Setup tab, so the same setting is never entered twice.
///
/// - Pasting a token and pressing Connect verifies it by listing the repos it
///   can see, stores it in the Keychain, and fills the repo picker.
/// - The repo picker is an editable combo box: choose from the list, or type
///   `owner/name` (one repo) or an org name (every repo in the org).
/// - Config writes go through `GeneralConfigEditor` (comments preserved,
///   engine-validated).
@MainActor
final class ConnectFormViewController: NSViewController {
    let model = ConnectModel()

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("created in code") }

    override func loadView() {
        view = NSHostingView(rootView: ConnectView(model: model))
        reload()
    }

    // MARK: Forwarding (the wizard, Accounts page, and tests use these)

    /// Persists a token (and live-swaps it into a running engine). Defaults
    /// to a plain Keychain save; the app injects the live-swap version.
    var saveToken: (ForgeID, String) async throws -> Void {
        get { model.saveToken }
        set { model.saveToken = newValue }
    }
    /// The config file this form edits (tests point it at a scratch file).
    var configURL: URL {
        get { model.configURL }
        set { model.configURL = newValue }
    }
    /// Whether a token is stored for a forge (tests stub this out so they
    /// never touch the real Keychain).
    var hasStoredToken: @Sendable (ForgeID) throws -> Bool {
        get { model.hasStoredToken }
        set { model.hasStoredToken = newValue }
    }
    /// Fired after any successful token or config change.
    var onChanged: (() -> Void)? {
        get { model.onChanged }
        set { model.onChanged = newValue }
    }
    /// True once at least one forge is fully connected (see `ConnectModel`).
    var isConnected: Bool { model.isConnected }

    /// Re-reads config + Keychain and refreshes both cards.
    func reload() { model.reload() }

    // MARK: Test hooks

    func didStoreTokenForTesting(_ forge: ForgeID) { model.didStoreToken(forge) }

    var repoFieldsEnabledForTesting: (github: Bool, gitea: Bool) { model.repoFieldsEnabledForTesting }
    func markTokensStoredForTesting(github: Bool, gitea: Bool) {
        model.markTokensStoredForTesting(github: github, gitea: gitea)
    }
    func enterGitHubRepoForTesting(_ value: String) { model.enterGitHubRepoForTesting(value) }
    func enterGiteaForTesting(instance: String, scope: String) {
        model.enterGiteaForTesting(instance: instance, scope: scope)
    }
}
