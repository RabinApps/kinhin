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
///   engine-validated): every forge edits its conventional `accounts:` entry
///   (`github`, `gitea`, `forgejo`, `gitlab`).
@MainActor
@Observable
final class ForgeConnectionModel: ConfigFormModel {
    typealias Line = StatusLine

    /// The conventional accounts: name this card writes — one per forge
    /// (`github`, `gitea`, `forgejo`, `gitlab`), matching the template.
    static func accountName(for forge: ForgeID) -> String { forge.rawValue }

    /// This card's accounts: name.
    var accountName: String { Self.accountName(for: forge) }

    /// True for the one `accounts:` entry a forge card owns: the forge's
    /// conventional name on that forge. Every other entry (a GitHub account
    /// named `work`, a second Gitea server) belongs to "More accounts".
    static func ownsAccount(_ account: AccountConfig) -> Bool {
        account.name == accountName(for: account.forge)
    }

    /// Fields the card can move keyboard focus to.
    enum Field: Hashable {
        case token(ForgeID)
        case instance(ForgeID)
    }

    let forge: ForgeID
    /// The config file this card edits (shared with the owning ConnectModel).
    var configURL: URL = Paths.config

    // MARK: - Injectable seams (wired by ConnectModel)

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
    /// `token` nil → use the stored one; `instance` is the enterprise host
    /// (nil → github.com). nil report = nothing to check.
    @ObservationIgnored var checkPermission:
        (_ scope: String, _ token: String?, _ instance: String?) async -> OrgPermissionProbe
            .Report? = { _, _, _ in nil }
    /// Fired after any successful token or config change.
    @ObservationIgnored var onChanged: (() -> Void)?

    // MARK: - Form state

    var tokenText = ""
    var instance = ""
    var scope = ""
    private(set) var repos: [String] = []
    var status = Line(text: String(localized: "Not connected yet.", bundle: .l10n, comment: "Forge card status line"))
    private(set) var checking = false

    @ObservationIgnored var tokenStored = false
    @ObservationIgnored var connected = false
    @ObservationIgnored var lastWrittenScope = ""
    @ObservationIgnored var lastWrittenInstance = ""

    init(forge: ForgeID) {
        self.forge = forge
    }

    // MARK: - Display

    /// Self-hosted forges and GitLab show a server field; GitHub now also
    /// shows an optional enterprise host. GHES uses your server's base URL;
    /// GHEC data residency uses the api.*.ghe.com form. Buildkite and
    /// Bitbucket are hosted only.
    var showsInstance: Bool { forge != .buildkite && forge != .bitbucket }
    var instancePlaceholder: String {
        switch forge {
        case .github:
            return String(
                localized: "e.g. https://github.example.com or https://acme.ghe.com", bundle: .l10n,
                comment: "Placeholder in the server address field; keep the example URLs verbatim")
        case .buildkite, .bitbucket: return ""
        case .gitea, .forgejo: return "https://gitea.example.com"
        case .gitlab:
            return String(
                localized: "https://gitlab.com (optional)", bundle: .l10n,
                comment: "Placeholder in the server address field; keep the URL verbatim")
        case .azuredevops:
            return String(
                localized: "https://dev.azure.com/your-org", bundle: .l10n,
                comment: "Placeholder in the server address field; keep the example URL verbatim")
        }
    }
    var scopeLabel: String {
        switch forge {
        case .gitlab:
            return String(localized: "Group or project", bundle: .l10n, comment: "Label of the repository field")
        case .buildkite:
            return String(
                localized: "Organization and cluster", bundle: .l10n, comment: "Label of the repository field")
        case .azuredevops:
            return String(localized: "Agent pool", bundle: .l10n, comment: "Label of the repository field")
        case .bitbucket:
            return String(
                localized: "Workspace or workspace/repo", bundle: .l10n, comment: "Label of the repository field")
        case .github, .gitea, .forgejo:
            return String(localized: "Repository or org", bundle: .l10n, comment: "Label of the repository field")
        }
    }
    var scopeEnabled: Bool { tokenStored }
    var buttonTitle: String {
        tokenStored
            ? String(localized: "Replace", bundle: .l10n, comment: "Forge card button when a token is already stored")
            : String(localized: "Connect", bundle: .l10n, comment: "Forge card button that saves the token")
    }
    var instanceEnabled: Bool { !connected }

    /// What the forge's token needs, for the scope currently entered.
    var requirements: TokenRequirements {
        let trimmedScope = scope.trimmingCharacters(in: .whitespaces)
        switch forge {
        case .github:
            return TokenRequirements.github(scope: trimmedScope, instance: instanceIfAny)
        case .gitea, .forgejo:
            return TokenRequirements.gitea(scope: trimmedScope, instance: instance.trimmingCharacters(in: .whitespaces))
        case .gitlab:
            return TokenRequirements.gitlab(
                scope: trimmedScope, instance: instance.trimmingCharacters(in: .whitespaces))
        case .buildkite:
            return TokenRequirements.buildkite(scope: trimmedScope)
        case .azuredevops:
            return TokenRequirements.azureDevOps(
                scope: trimmedScope, instance: instance.trimmingCharacters(in: .whitespaces))
        case .bitbucket:
            return TokenRequirements.bitbucket(scope: trimmedScope)
        }
    }

    static func scopePlaceholder(enabled: Bool, forge: ForgeID) -> String {
        guard enabled else {
            return String(
                localized: "Connect first to choose a repository", bundle: .l10n,
                comment: "Placeholder in the repository field while disabled")
        }
        switch forge {
        case .gitlab:
            return String(
                localized: "group/subgroup or group/project", bundle: .l10n,
                comment: "Placeholder in the repository field; keep the path syntax verbatim")
        case .buildkite:
            return String(
                localized: "org-slug/cluster", bundle: .l10n,
                comment: "Placeholder in the repository field; keep the syntax verbatim")
        case .azuredevops:
            return String(localized: "agent pool name", bundle: .l10n, comment: "Placeholder in the repository field")
        case .bitbucket:
            return String(
                localized: "workspace, or workspace/repo-slug", bundle: .l10n,
                comment: "Placeholder in the repository field; keep the syntax verbatim")
        case .github, .gitea, .forgejo:
            return String(
                localized: "owner/name, or an org name", bundle: .l10n,
                comment: "Placeholder in the repository field; keep the syntax verbatim")
        }
    }

    // MARK: - Loading

    /// Re-reads config + Keychain (off the main thread — a Keychain read can
    /// block on a system prompt) and refreshes the card.
    func reload() {
        Task { [weak self] in
            guard let self else { return }
            let probe = self.hasStoredToken
            let stored = await Task.detached { Result { try probe() } }.value
            self.render(stored: stored)
        }
    }

    /// `stored` is the Keychain probe. A failed probe shows the Keychain
    /// error on the card instead of "Not connected yet", and leaves the token
    /// treated as absent for the buttons.
    private func render(stored: Result<Bool, Error>) {
        // A failed probe leaves the token treated as absent for the buttons
        // (the card itself already shows the probe error), but it is logged
        // so a broken Keychain is not indistinguishable from "no token".
        let hasToken: Bool
        do {
            hasToken = try stored.get()
        } catch {
            Log.warn("app", "\(forge.rawValue) token probe failed: \(error.localizedDescription)")
            hasToken = false
        }
        let account = Self.configuredAccount(forge: forge, at: configURL)
        lastWrittenScope = account?.scope ?? ""
        lastWrittenInstance = account?.instance ?? ""
        if let account {
            instance = account.instance ?? ""
            scope = account.scope
        }
        tokenStored = hasToken
        connected =
            hasToken
            && Self.countsAsConnected(
                forge: forge, scope: lastWrittenScope, instance: lastWrittenInstance)
        if case .failure(let error) = stored {
            status = Line(
                text: String(
                    localized: "Keychain error — \(error.localizedDescription)", bundle: .l10n,
                    comment: "Forge card status; %@ is the Keychain error"), style: .error)
        } else {
            status = Line(
                text: hasToken
                    ? Self.storedTokenText
                    : String(localized: "Not connected yet.", bundle: .l10n, comment: "Forge card status"),
                style: hasToken ? .secondary : .warn)
        }
        if hasToken { Task { await listRepos(token: nil) } }
    }

    private static let storedTokenText = String(
        localized: "Token stored in your Keychain ✓ — paste a new one only to replace it.", bundle: .l10n,
        comment: "Forge card status when a token is already stored")

    /// A forge counts as connected once it has a scope — except the
    /// self-hosted forges, which also need a server address. GitHub is
    /// hosted by default (github.com) but can be given an enterprise host,
    /// so a stored scope is enough on its own.
    static func countsAsConnected(forge: ForgeID, scope: String, instance: String) -> Bool {
        switch forge {
        case .gitea, .forgejo: return !scope.isEmpty && !instance.isEmpty
        default: return !scope.isEmpty
        }
    }

    /// The `accounts:` entry this card writes (nil when absent). A failed
    /// read is treated as unconfigured; the write path surfaces the error.
    static func configuredAccount(forge: ForgeID, at url: URL) -> AccountConfig? {
        do {
            return try AccountsConfigEditor.accounts(at: url).first { $0.forge == forge && ownsAccount($0) }
        } catch {
            // No file or unreadable config: treat as unconfigured; the write
            // path surfaces the real error.
            return nil
        }
    }

    // MARK: - Connect

    func connect() {
        let typed = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if showsInstance,
            forge != .gitlab,
            forge != .github,
            instance.trimmingCharacters(in: .whitespaces).isEmpty
        {
            status = Line(
                text: String(
                    localized: "Enter your \(forge.displayName) server address first.", bundle: .l10n,
                    comment: "Forge card status; %@ is a forge name"), style: .warn)
            return
        }
        guard !typed.isEmpty else {
            status = Line(
                text: String(localized: "Paste a token first.", bundle: .l10n, comment: "Forge card status"),
                style: .warn)
            return
        }
        checking = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.checking = false }
            self.status = Line(
                text: String(
                    localized: "Checking the token…", bundle: .l10n,
                    comment: "Forge card status while the token is verified"))
            guard await self.listRepos(token: typed) else { return }
            do {
                try await self.saveToken(typed)
                self.tokenText = ""
                self.didStoreToken()
                await self.verifyAfterConnect(with: typed)
            } catch {
                self.status = Line(
                    text: String(
                        localized: "Couldn't save the token — \(error.localizedDescription)", bundle: .l10n,
                        comment: "Forge card status; %@ is the reason"), style: .error)
            }
        }
    }

    /// A token was just saved: unlock the scope picker, count the forge as
    /// connected when a scope is already chosen, and write any scope or
    /// server the user entered before connecting. Without this the card kept
    /// treating the forge as unconnected until the next reload.
    func didStoreToken() {
        tokenStored = true
        connected = Self.countsAsConnected(
            forge: forge, scope: lastWrittenScope, instance: lastWrittenInstance)
        commit()
        onChanged?()
    }

    /// GitHub probes runner-management permission; GitLab checks version,
    /// scopes and scope resolution; Buildkite checks scopes and the cluster;
    /// Gitea-family has no token model to probe.
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
        case .buildkite:
            let scopeValue = scope.trimmingCharacters(in: .whitespaces)
            guard !scopeValue.isEmpty else { return }
            let report = await TokenHealthCheck.buildkite(token: token, scope: scopeValue)
            status = Line(text: report.message, style: report.ok ? .ok : .error)
        case .azuredevops:
            let scopeValue = scope.trimmingCharacters(in: .whitespaces)
            guard !scopeValue.isEmpty, let instance = instanceIfAny else { return }
            let report = await TokenHealthCheck.azureDevOps(token: token, scope: scopeValue, instance: instance)
            status = Line(text: report.message, style: report.ok ? .ok : .error)
        case .bitbucket:
            let scopeValue = scope.trimmingCharacters(in: .whitespaces)
            guard !scopeValue.isEmpty else { return }
            let report = await TokenHealthCheck.bitbucket(token: token, scope: scopeValue)
            status = Line(text: report.message, style: report.ok ? .ok : .error)
        case .gitea, .forgejo:
            break
        }
    }

    var instanceIfAny: String? {
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
            status = Line(
                text: String(
                    localized: "Keychain error — \(error.localizedDescription)", bundle: .l10n,
                    comment: "Forge card status; %@ is the Keychain error"), style: .error)
            return false
        }
        guard let resolved else { return false }
        do {
            if forge == .gitea || forge == .forgejo || forge == .azuredevops, instanceIfAny == nil { return false }
            let refs = try await TokenHealthCheck.repositories(forge: forge, token: resolved, instance: instanceIfAny)
            repos = refs.prefix(300).map(\.fullName)
            if token != nil {
                status = Line(
                    text: String(
                        localized: "Connected ✓ — \(refs.count) repositories visible. Pick one below.", bundle: .l10n,
                        comment: "Forge card status; plural by the number of repositories the token can see"),
                    style: .ok)
            }
            return true
        } catch {
            if token != nil {
                status = Line(
                    text: String(
                        localized:
                            "That token didn't work — \(error.localizedDescription)\nIt needs — \(requirements.summary)",
                        bundle: .l10n,
                        comment: "Forge card status; first is the forge's error, second what the token needs"),
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
    func verifyPermission(scope: String, token: String?) async {
        guard let report = await checkPermission(scope, token, instanceIfAny) else { return }
        status = Line(text: report.message, style: report.ok ? .ok : .error)
    }

}
