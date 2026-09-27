import Foundation
import KinhinKit
import Observation

/// State and actions behind one forge's Connect card — GitHub, GitLab, Gitea
/// and Forgejo all run through this one model, selected by `forge`:
///
/// - Pasting a token and pressing Connect verifies it by listing what it can
///   see, stores it in the Keychain, and fills the scope picker.
/// - The scope picker is an editable combo box: choose from the list, or type
///   a path (one repo / project) or a name (every repo in an org / group).
/// - Config writes go through the editors (comments preserved,
///   engine-validated): GitHub → `repo:`, Gitea/Forgejo → `gitea:` /
///   `forgejo:`, GitLab → the `accounts:` entry named `gitlab`.
@MainActor
@Observable
final class ForgeConnectionModel {
    typealias Line = StatusLine

    /// GitLab has no top-level section; its card edits this account.
    static let gitlabAccountName = "gitlab"

    /// Fields the card can move keyboard focus to.
    enum Field: Hashable {
        case token(ForgeID)
        case instance(ForgeID)
    }

    let forge: ForgeID
    /// The config file this card edits (shared with the owning ConnectModel).
    var configURL: URL = Paths.config

    // MARK: Injectable seams (wired by ConnectModel)

    /// Persists a token (and live-swaps it into a running engine).
    @ObservationIgnored var saveToken: (String) async throws -> Void = { _ in }
    /// Whether a token is stored for this forge (tests stub this out so they
    /// never touch the real Keychain).
    @ObservationIgnored var hasStoredToken: @Sendable () throws -> Bool = { false }
    /// The stored token itself, for listing what it can see.
    @ObservationIgnored var loadToken: @Sendable () throws -> String? = { nil }
    /// Deletes the stored token when the forge is deselected.
    @ObservationIgnored var deleteToken: () -> Void = {}
    /// Checks runner-management permission for a scope (GitHub only).
    /// `token` nil → use the stored one. nil report = nothing to check.
    @ObservationIgnored var checkPermission:
        (_ scope: String, _ token: String?) async -> OrgPermissionProbe
            .Report? = { _, _ in nil }
    /// Fired after any successful token or config change.
    @ObservationIgnored var onChanged: (() -> Void)?

    // MARK: Form state

    var tokenText = ""
    var instance = ""
    var scope = ""
    private(set) var repos: [String] = []
    private(set) var status = Line(text: "Not connected yet.")
    private(set) var checking = false

    @ObservationIgnored private(set) var tokenStored = false
    @ObservationIgnored private(set) var connected = false
    @ObservationIgnored private var lastWrittenScope = ""
    @ObservationIgnored private var lastWrittenInstance = ""
    @ObservationIgnored private var lastWrittenGitea: GeneralConfigEditor.Snapshot.Gitea?

    init(forge: ForgeID) {
        self.forge = forge
    }

    // MARK: Display

    /// Self-hosted forges and GitLab show a server field; GitHub tokens work
    /// without one.
    var showsInstance: Bool { forge != .github }
    var instancePlaceholder: String {
        switch forge {
        case .github: return ""
        case .gitea, .forgejo: return "https://gitea.example.com"
        case .gitlab: return "https://gitlab.com (optional)"
        }
    }
    var scopeLabel: String {
        forge == .gitlab ? "Group or project" : "Repository or org"
    }
    var scopeEnabled: Bool { tokenStored }
    var buttonTitle: String { tokenStored ? "Replace" : "Connect" }
    var instanceEnabled: Bool { !connected }

    /// What the forge's token needs, for the scope currently entered.
    var requirements: TokenRequirements {
        let trimmedScope = scope.trimmingCharacters(in: .whitespaces)
        switch forge {
        case .github:
            return TokenRequirements.github(scope: trimmedScope)
        case .gitea, .forgejo:
            return TokenRequirements.gitea(scope: trimmedScope, instance: instance.trimmingCharacters(in: .whitespaces))
        case .gitlab:
            return TokenRequirements.gitlab(
                scope: trimmedScope, instance: instance.trimmingCharacters(in: .whitespaces))
        }
    }

    static func scopePlaceholder(enabled: Bool, forge: ForgeID) -> String {
        guard enabled else { return "Connect first to choose a repository" }
        return forge == .gitlab ? "group/subgroup or group/project" : "owner/name, or an org name"
    }

    // MARK: Loading

    /// Re-reads config + Keychain (off the main thread — a Keychain read can
    /// block on a system prompt) and refreshes the card.
    func reload() {
        let snapshot = ConfigStore.snapshotOrLog(at: configURL)
        Task { [weak self] in
            guard let self else { return }
            let probe = self.hasStoredToken
            let stored = await Task.detached { Result { try probe() } }.value
            self.render(snapshot: snapshot, stored: stored)
        }
    }

    /// `stored` is the Keychain probe. A failed probe shows the Keychain
    /// error on the card instead of "Not connected yet", and leaves the token
    /// treated as absent for the buttons.
    private func render(snapshot: GeneralConfigEditor.Snapshot?, stored: Result<Bool, Error>) {
        let hasToken = (try? stored.get()) ?? false
        switch forge {
        case .github:
            let repo = snapshot?.repo ?? ""
            let configuredRepo = (repo == ConfigLoader.templateRepo) ? "" : repo
            lastWrittenScope = configuredRepo
            scope = configuredRepo
        case .gitea, .forgejo:
            let section = snapshot?.gitea
            lastWrittenGitea = section
            if let section {
                instance = section.instance
                scope = section.scope
            }
        case .gitlab:
            let account = Self.configuredGitLabAccount(at: configURL)
            lastWrittenScope = account?.scope ?? ""
            lastWrittenInstance = account?.instance ?? ""
            if let account {
                instance = account.instance ?? ""
                scope = account.scope
            }
        }
        tokenStored = hasToken
        connected =
            hasToken
            && Self.countsAsConnected(
                forge: forge, scope: lastWrittenScope, gitea: lastWrittenGitea)
        if case .failure(let error) = stored {
            status = Line(text: "Keychain error — \(error.localizedDescription)", style: .error)
        } else {
            status = Line(
                text: hasToken ? Self.storedTokenText : "Not connected yet.",
                style: hasToken ? .secondary : .warn)
        }
        if hasToken { Task { await listRepos(token: nil) } }
    }

    private static let storedTokenText = "Token stored in your Keychain ✓ — paste a new one only to replace it."

    private static func countsAsConnected(forge: ForgeID, scope: String, gitea: GeneralConfigEditor.Snapshot.Gitea?)
        -> Bool
    {
        switch forge {
        case .github, .gitlab:
            return !scope.isEmpty
        case .gitea, .forgejo:
            return gitea != nil && !gitea!.scope.isEmpty && !gitea!.instance.isEmpty
        }
    }

    /// The `accounts:` entry this card's GitLab account writes to (nil when
    /// absent). A failed read is reported through the card's status instead.
    static func configuredGitLabAccount(at url: URL) -> AccountConfig? {
        do {
            return try AccountsConfigEditor.accounts(at: url).first { $0.forge == .gitlab }
        } catch {
            // No file or unreadable config: treat as unconfigured; the write
            // path surfaces the real error.
            return nil
        }
    }

    // MARK: Connect

    func connect() {
        let typed = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if showsInstance, forge != .gitlab, instance.trimmingCharacters(in: .whitespaces).isEmpty {
            status = Line(text: "Enter your \(forge.displayName) server address first.", style: .warn)
            return
        }
        guard !typed.isEmpty else {
            status = Line(text: "Paste a token first.", style: .warn)
            return
        }
        checking = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.checking = false }
            self.status = Line(text: "Checking the token…")
            guard await self.listRepos(token: typed) else { return }
            do {
                try await self.saveToken(typed)
                self.tokenText = ""
                self.didStoreToken()
                await self.verifyAfterConnect(with: typed)
            } catch {
                self.status = Line(text: "Couldn't save the token — \(error.localizedDescription)", style: .error)
            }
        }
    }

    /// A token was just saved: unlock the scope picker, count the forge as
    /// connected when a scope is already chosen, and write any scope or
    /// server the user entered before connecting. Without this the card kept
    /// treating the forge as unconnected until the next reload.
    func didStoreToken() {
        tokenStored = true
        connected = Self.countsAsConnected(forge: forge, scope: lastWrittenScope, gitea: lastWrittenGitea)
        commit()
        onChanged?()
    }

    /// GitHub probes runner-management permission; GitLab checks version,
    /// scopes and scope resolution; Gitea-family has no token model to probe.
    private func verifyAfterConnect(with token: String) async {
        switch forge {
        case .github:
            await verifyPermission(scope: scope.trimmingCharacters(in: .whitespaces), token: token)
        case .gitlab:
            let scopeValue = scope.trimmingCharacters(in: .whitespaces)
            guard !scopeValue.isEmpty else { return }
            let report = await TokenHealthCheck.gitlab(
                token: token, scope: scopeValue, instance: instanceIfAny)
            status = Line(text: report.message, style: report.ok ? .ok : .error)
        case .gitea, .forgejo:
            break
        }
    }

    private var instanceIfAny: String? {
        let trimmed = instance.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Lists what the token can see and fills the picker. `token` nil → use
    /// the stored one. Returns false (with a message) on failure.
    @discardableResult
    private func listRepos(token: String?) async -> Bool {
        let resolved: String?
        do {
            if let token {
                resolved = token
            } else {
                let load = self.loadToken
                resolved = try await Task.detached { try load() }.value
            }
        } catch {
            status = Line(text: "Keychain error — \(error.localizedDescription)", style: .error)
            return false
        }
        guard let resolved else { return false }
        do {
            let refs: [RepoRef]
            switch forge {
            case .github:
                refs = try await GitHubClient(credentials: GitHubCredentials(token: resolved, scope: ""))
                    .listRepositories()
            case .gitea, .forgejo:
                guard let instanceValue = instanceIfAny else { return false }
                refs = try await GiteaClient(
                    credentials: GiteaCredentials(token: resolved, scope: "", instance: instanceValue)
                ).listRepositories()
            case .gitlab:
                refs = try await GitLabClient(
                    credentials: GitLabCredentials(token: resolved, scope: "", instance: instanceIfAny)
                ).listRepositories()
            }
            repos = refs.prefix(300).map(\.fullName)
            if token != nil {
                status = Line(
                    text: "Connected ✓ — \(refs.count) repositories visible. Pick one below.", style: .ok)
            }
            return true
        } catch {
            if token != nil {
                status = Line(
                    text: "That token didn't work — \(error.localizedDescription)\nIt needs — \(requirements.summary)",
                    style: .error)
            }
            return false
        }
    }

    /// Verify the runner-management permission for the live scope, with the
    /// token just entered (or the stored one when `token` is nil). For org
    /// scopes this surfaces the PAT-permission error with its remediation
    /// instead of the generic "Now serving" line. Nothing is shown when there
    /// is no repo or org to check yet. GitHub only: the other forges have no
    /// runner-management token probe.
    private func verifyPermission(scope: String, token: String?) async {
        guard let report = await checkPermission(scope, token) else { return }
        status = Line(text: report.message, style: report.ok ? .ok : .error)
    }

    // MARK: Config writes

    /// Writes the entered scope (and server), once the token is stored.
    func commit() {
        let scopeValue = scope.trimmingCharacters(in: .whitespaces)
        guard tokenStored, !scopeValue.isEmpty else { return }
        do {
            switch forge {
            case .github:
                guard scopeValue != lastWrittenScope else { return }
                try GeneralConfigEditor.apply(.repo(scopeValue), to: configURL)
                lastWrittenScope = scopeValue
                status = Line(text: "Now serving \(scopeValue) ✓", style: .ok)
                connected = tokenStored
                onChanged?()
                // Now that there is a scope, check the token can manage its runners.
                Task { [weak self] in await self?.verifyPermission(scope: scopeValue, token: nil) }
            case .gitea, .forgejo:
                guard let instanceValue = instanceIfAny else { return }
                let section = GeneralConfigEditor.Snapshot.Gitea(instance: instanceValue, scope: scopeValue)
                guard section != lastWrittenGitea else { return }
                try GeneralConfigEditor.apply(.gitea(section), to: configURL)
                lastWrittenGitea = section
                connected = tokenStored
                status = Line(text: "Now serving \(scopeValue) on \(forge.displayName) ✓", style: .ok)
                onChanged?()
            case .gitlab:
                let instanceValue = instanceIfAny
                guard scopeValue != lastWrittenScope || instanceValue != lastWrittenInstanceIfAny else { return }
                var account = AccountConfig(name: Self.gitlabAccountName, forge: .gitlab, scope: scopeValue)
                account.instance = instanceValue
                if try AccountsConfigEditor.accounts(at: configURL).contains(where: {
                    $0.name == Self.gitlabAccountName
                }) {
                    try AccountsConfigEditor.update(account, at: configURL)
                } else {
                    try AccountsConfigEditor.add(account, to: configURL)
                    if let fresh = try AccountsConfigEditor.accounts(at: configURL).first(where: {
                        $0.name == Self.gitlabAccountName
                    }) {
                        account = fresh
                    }
                }
                lastWrittenScope = scopeValue
                lastWrittenInstance = instanceValue ?? ""
                connected = tokenStored
                status = Line(text: "Now serving \(scopeValue) on GitLab ✓", style: .ok)
                onChanged?()
            }
        } catch {
            status = Line(text: "Not saved — \(error.localizedDescription)", style: .error)
        }
    }

    private var lastWrittenInstanceIfAny: String? {
        lastWrittenInstance.isEmpty ? nil : lastWrittenInstance
    }

    // MARK: Deselect

    /// Whether this card has anything on disk (config entry or token) that
    /// deselecting would remove — used to skip the confirmation for a forge
    /// that was merely selected.
    var hasCommittedState: Bool {
        tokenStored
            || (forge == .gitea || forge == .forgejo ? lastWrittenGitea != nil : !lastWrittenScope.isEmpty)
    }

    /// Removes the forge's config entry and Keychain token. A failed config
    /// write shows on the card's status line and rethrows, so the caller can
    /// keep the card open for a retry instead of half-removing the forge.
    func deselect() throws {
        do {
            switch forge {
            case .github:
                // Reset to the template so the file stays valid and "no repo"
                // reads back as unconfigured.
                try GeneralConfigEditor.apply(.repo(ConfigLoader.templateRepo), to: configURL)
            case .gitea, .forgejo:
                try GeneralConfigEditor.apply(.gitea(nil), to: configURL)
            case .gitlab:
                try AccountsConfigEditor.remove(name: Self.gitlabAccountName, at: configURL)
            }
        } catch {
            status = Line(text: "Couldn't remove — \(error.localizedDescription)", style: .error)
            throw error
        }
        deleteToken()
        tokenStored = false
        connected = false
        lastWrittenScope = ""
        lastWrittenInstance = ""
        lastWrittenGitea = nil
        status = Line(text: "Not connected yet.", style: .warn)
        onChanged?()
    }

    // MARK: Test hooks

    func show(_ line: Line) { status = line }

    func markTokenStoredForTesting(_ stored: Bool) {
        tokenStored = stored
        connected = stored && Self.countsAsConnected(forge: forge, scope: lastWrittenScope, gitea: lastWrittenGitea)
    }

    func enterScopeForTesting(_ value: String) {
        scope = value
        commit()
    }

    func enterForTesting(instance: String, scope: String) {
        self.instance = instance
        self.scope = scope
        commit()
    }
}
