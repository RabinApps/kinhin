import Foundation
import KinhinKit
import Observation

/// State and actions behind the Connect form: a GitHub card (token → repo or
/// org) and an optional self-hosted Gitea card. Used by both the onboarding
/// wizard and the Setup tab, so the same setting is never entered twice.
///
/// - Pasting a token and pressing Connect verifies it by listing the repos it
///   can see, stores it in the Keychain, and fills the repo picker.
/// - The repo picker is an editable combo box: choose from the list, or type
///   `owner/name` (one repo) or an org name (every repo in the org).
/// - Config writes go through `GeneralConfigEditor` (comments preserved,
///   engine-validated).
@MainActor
@Observable
final class ConnectModel {
    typealias Line = StatusLine

    /// Fields the model can ask the view to focus.
    enum Field: Hashable {
        case githubToken, giteaInstance, giteaToken
    }

    /// The "More accounts" section (extra GitHub/Gitea accounts).
    let accounts = AccountsModel()

    // MARK: Injectable seams

    /// Persists a token (and live-swaps it into a running engine). Defaults
    /// to a plain Keychain save; the app injects the live-swap version.
    @ObservationIgnored var saveToken: (ForgeID, String) async throws -> Void = { forge, token in
        try KeychainTokenStore.save(token, forge: forge)
    }
    /// The config file this form edits (tests point it at a scratch file).
    var configURL: URL = Paths.config {
        didSet { accounts.configURL = configURL }
    }
    /// Whether a token is stored for a forge (tests stub this out so they
    /// never touch the real Keychain).
    @ObservationIgnored var hasStoredToken: @Sendable (ForgeID) -> Bool = { KeychainTokenStore.load(forge: $0) != nil }
    /// Fired after any successful token or config change.
    @ObservationIgnored var onChanged: (() -> Void)? {
        didSet { accounts.onChanged = onChanged }
    }
    /// Checks runner-management permission for a scope. `token` nil → use the
    /// stored one. Returns nil when there is nothing to check (no token, or
    /// no repo/org chosen yet). Injectable so tests never hit the network.
    @ObservationIgnored var checkPermission: (_ scope: String, _ token: String?) async -> OrgPermissionProbe.Report? = {
        scope, token in
        let resolved: String? =
            if let token { token } else { await Task.detached { KeychainTokenStore.load(forge: .github) }.value }
        guard let resolved, !scope.isEmpty else { return nil }
        return await OrgPermissionProbe.verify(
            github: GitHubClient(credentials: GitHubCredentials(token: resolved, scope: scope)), scope: scope)
    }

    // MARK: Form state

    var githubTokenText = ""
    var githubRepo = ""
    private(set) var githubRepos: [String] = []
    private(set) var githubStatus = Line(text: "Not connected yet.")
    private(set) var githubButtonTitle = "Connect"
    private(set) var githubChecking = false

    /// The Gitea section is shown while this is on.
    private(set) var giteaEnabled = false
    var giteaInstance = ""
    var giteaTokenText = ""
    var giteaScope = ""
    private(set) var giteaRepos: [String] = []
    private(set) var giteaStatus = Line(text: "Not connected yet.")
    private(set) var giteaButtonTitle = "Connect"
    private(set) var giteaChecking = false

    /// Set to move keyboard focus; the view clears it once applied.
    var focusRequest: Field?

    // MARK: Derived state

    /// True once at least one forge is fully connected: GitHub (stored token
    /// + real repo/org) or Gitea (stored token + server + scope). Either one
    /// alone is enough to run a fleet.
    var isConnected: Bool { githubConnected || giteaConnected || accounts.rows.contains { $0.tokenStored } }
    private var githubConnected = false
    private var giteaConnected = false
    private var githubTokenStored = false
    private var giteaTokenStored = false
    private var lastWrittenRepo = ""
    private var lastWrittenGitea: GeneralConfigEditor.Snapshot.Gitea?

    /// A repository can only be chosen once its forge is connected: without a
    /// token there is nothing to list or verify against.
    var githubRepoEnabled: Bool { githubTokenStored }
    var giteaScopeEnabled: Bool { giteaTokenStored }

    /// What each forge's token needs, for the scope currently entered.
    var githubRequirements: TokenRequirements { TokenRequirements.github(scope: githubRepo) }
    var giteaRequirements: TokenRequirements { TokenRequirements.gitea(scope: giteaScope, instance: giteaInstance) }

    static func repoPlaceholder(enabled: Bool) -> String {
        enabled ? "owner/name, or an org name" : "Connect first to choose a repository"
    }

    private static let storedTokenText = "Token stored in your Keychain ✓ — paste a new one only to replace it."

    // MARK: Loading

    /// Re-reads config + Keychain (off the main thread — a Keychain read can
    /// block on a system prompt) and refreshes both cards.
    func reload() {
        accounts.reload()
        let snapshot = ConfigStore.snapshotOrLog(at: configURL)
        Task { [weak self] in
            let probe = self?.hasStoredToken ?? { _ in false }
            let tokens = await Task.detached { (probe(.github), probe(.gitea)) }.value
            self?.render(snapshot: snapshot, hasGitHubToken: tokens.0, hasGiteaToken: tokens.1)
        }
    }

    private func render(snapshot: GeneralConfigEditor.Snapshot?, hasGitHubToken: Bool, hasGiteaToken: Bool) {
        let repo = snapshot?.repo ?? ""
        let configuredRepo = (repo == ConfigLoader.templateRepo) ? "" : repo
        lastWrittenRepo = configuredRepo
        githubRepo = configuredRepo
        githubStatus = Line(
            text: hasGitHubToken ? Self.storedTokenText : "Not connected yet.",
            style: hasGitHubToken ? .secondary : .warn)
        githubButtonTitle = hasGitHubToken ? "Replace" : "Connect"
        githubTokenStored = hasGitHubToken
        githubConnected = hasGitHubToken && !configuredRepo.isEmpty

        let gitea = snapshot?.gitea
        lastWrittenGitea = gitea
        giteaTokenStored = hasGiteaToken
        giteaConnected = hasGiteaToken && gitea != nil
        if gitea != nil { giteaEnabled = true }
        if let gitea {
            giteaInstance = gitea.instance
            giteaScope = gitea.scope
        }
        giteaStatus = Line(
            text: hasGiteaToken ? Self.storedTokenText : "Not connected yet.",
            style: hasGiteaToken ? .secondary : .warn)
        giteaButtonTitle = hasGiteaToken ? "Replace" : "Connect"

        if hasGitHubToken { Task { await listRepos(forge: .github, token: nil) } }
        if hasGiteaToken, gitea != nil { Task { await listRepos(forge: .gitea, token: nil) } }
    }

    // MARK: Connect

    func connectGitHub() {
        let typed = githubTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            focusRequest = .githubToken
            return
        }
        githubChecking = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.githubChecking = false }
            self.githubStatus = Line(text: "Checking the token…")
            guard await self.listRepos(forge: .github, token: typed) else { return }
            do {
                try await self.saveToken(.github, typed)
                self.githubTokenText = ""
                self.didStoreToken(.github)
                await self.verifyPermission(scope: self.githubRepo.trimmingCharacters(in: .whitespaces), token: typed)
            } catch {
                self.githubStatus = Line(text: "Couldn't save the token — \(error.localizedDescription)", style: .error)
            }
        }
    }

    func connectGitea() {
        let typed = giteaTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !giteaInstance.trimmingCharacters(in: .whitespaces).isEmpty else {
            giteaStatus = Line(text: "Enter your Gitea server address first.", style: .warn)
            return
        }
        guard !typed.isEmpty else {
            focusRequest = .giteaToken
            return
        }
        giteaChecking = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.giteaChecking = false }
            self.giteaStatus = Line(text: "Checking the token…")
            guard await self.listRepos(forge: .gitea, token: typed) else { return }
            do {
                try await self.saveToken(.gitea, typed)
                self.giteaTokenText = ""
                self.didStoreToken(.gitea)
                // Gitea has no runner-management token model; no probe needed.
            } catch {
                self.giteaStatus = Line(text: "Couldn't save the token — \(error.localizedDescription)", style: .error)
            }
        }
    }

    /// A token was just saved: unlock the repo picker, count the forge as
    /// connected when a repo/org is already chosen, and write any repo or
    /// server the user entered before connecting. Without this the form kept
    /// treating the forge as unconnected until the next reload.
    func didStoreToken(_ forge: ForgeID) {
        switch forge {
        case .github:
            githubTokenStored = true
            githubButtonTitle = "Replace"
            githubConnected = !lastWrittenRepo.isEmpty
            commitGitHubRepo()
        case .gitea:
            giteaTokenStored = true
            giteaButtonTitle = "Replace"
            giteaConnected = lastWrittenGitea != nil
            commitGitea()
        }
        onChanged?()
    }

    /// Lists the repos a token can see and fills the matching picker. `token`
    /// nil → use the stored one. Returns false (with a message) on failure.
    @discardableResult
    private func listRepos(forge: ForgeID, token: String?) async -> Bool {
        let resolved: String? =
            if let token { token } else {
                await Task.detached { KeychainTokenStore.load(forge: forge) }.value
            }
        guard let resolved else { return false }
        do {
            let refs: [RepoRef]
            switch forge {
            case .github:
                refs = try await GitHubClient(credentials: GitHubCredentials(token: resolved, scope: ""))
                    .listRepositories()
            case .gitea:
                let instance = giteaInstance.trimmingCharacters(in: .whitespaces)
                guard !instance.isEmpty else { return false }
                refs = try await GiteaClient(
                    credentials: GiteaCredentials(token: resolved, scope: "", instance: instance)
                ).listRepositories()
            }
            let names = refs.prefix(300).map(\.fullName)
            if forge == .github { githubRepos = names } else { giteaRepos = names }
            if token != nil {
                let line = Line(
                    text: "Connected ✓ — \(refs.count) repositories visible. Pick one below.", style: .ok)
                if forge == .github { githubStatus = line } else { giteaStatus = line }
            }
            return true
        } catch {
            if token != nil {
                let needs = forge == .github ? githubRequirements : giteaRequirements
                let line = Line(
                    text: "That token didn't work — \(error.localizedDescription)\nIt needs — \(needs.summary)",
                    style: .error)
                if forge == .github { githubStatus = line } else { giteaStatus = line }
            }
            return false
        }
    }

    /// Verify the runner-management permission for the live scope, with the
    /// token just entered (or the stored one when `token` is nil). For org
    /// scopes this surfaces the PAT-permission error with its remediation
    /// instead of the generic "Connected ✓". Nothing is shown when there is
    /// no repo or org to check yet. GitHub only: Gitea doesn't use OAuth
    /// runner-management tokens.
    private func verifyPermission(scope: String, token: String?) async {
        guard let report = await checkPermission(scope, token) else { return }
        githubStatus = Line(text: report.message, style: report.ok ? .ok : .error)
        githubButtonTitle = report.ok ? "Replace" : "Connect"
    }

    // MARK: Config writes

    func commitGitHubRepo() {
        let value = githubRepo.trimmingCharacters(in: .whitespaces)
        guard githubTokenStored, !value.isEmpty, value != lastWrittenRepo else { return }
        do {
            try GeneralConfigEditor.apply(.repo(value), to: configURL)
            lastWrittenRepo = value
            githubStatus = Line(text: "Now serving \(value) ✓", style: .ok)
            githubConnected = githubTokenStored
            onChanged?()
            // Now that there is a scope, check the token can manage its runners.
            Task { [weak self] in await self?.verifyPermission(scope: value, token: nil) }
        } catch {
            githubStatus = Line(text: "Not saved — \(error.localizedDescription)", style: .error)
        }
    }

    func setGiteaEnabled(_ on: Bool) {
        giteaEnabled = on
        guard !on, lastWrittenGitea != nil else { return }
        do {
            try GeneralConfigEditor.apply(.gitea(nil), to: configURL)
            lastWrittenGitea = nil
            giteaConnected = false
            onChanged?()
        } catch {
            giteaStatus = Line(text: "Not saved — \(error.localizedDescription)", style: .error)
        }
    }

    /// The `gitea:` section needs both a server and a scope; write it once
    /// both are known.
    func commitGitea() {
        let instance = giteaInstance.trimmingCharacters(in: .whitespaces)
        let scope = giteaScope.trimmingCharacters(in: .whitespaces)
        guard giteaTokenStored, !instance.isEmpty, !scope.isEmpty else { return }
        let section = GeneralConfigEditor.Snapshot.Gitea(instance: instance, scope: scope)
        guard section != lastWrittenGitea else { return }
        do {
            try GeneralConfigEditor.apply(.gitea(section), to: configURL)
            lastWrittenGitea = section
            giteaConnected = giteaTokenStored
            giteaStatus = Line(text: "Now serving \(scope) on Gitea ✓", style: .ok)
            onChanged?()
        } catch {
            giteaStatus = Line(text: "Not saved — \(error.localizedDescription)", style: .error)
        }
    }

    // MARK: Test hooks

    var repoFieldsEnabledForTesting: (github: Bool, gitea: Bool) { (githubRepoEnabled, giteaScopeEnabled) }

    func markTokensStoredForTesting(github: Bool, gitea: Bool) {
        githubTokenStored = github
        giteaTokenStored = gitea
        githubConnected = github && !lastWrittenRepo.isEmpty
        giteaConnected = gitea && lastWrittenGitea != nil
    }

    func enterGitHubRepoForTesting(_ value: String) {
        githubRepo = value
        commitGitHubRepo()
    }

    func enterGiteaForTesting(instance: String, scope: String) {
        giteaEnabled = true
        giteaInstance = instance
        giteaScope = scope
        commitGitea()
    }
}
