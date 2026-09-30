import Foundation
import KinhinKit
import Observation

/// State and actions behind the "More accounts" section of the Connect form:
/// any number of extra accounts, of every forge, each with its own scope,
/// optional instance, and Keychain token. (The two top-level cards keep the
/// original `repo:` and `gitea:` accounts.) Config writes go through
/// `AccountsConfigEditor`.
@MainActor
@Observable
final class AccountsModel {
    struct Row: Identifiable, Equatable {
        var account: AccountConfig
        var tokenStored: Bool
        var status: StatusLine
        var checking = false
        var id: String { account.name }
    }

    // MARK: Injectable seams

    /// The config file this section edits (tests point it at a scratch file).
    var configURL: URL = Paths.config
    /// Persists a token (and live-swaps it into a running engine). Defaults
    /// to a plain Keychain save; the app injects the live-swap version.
    @ObservationIgnored var saveToken: (AccountConfig, String) async throws -> Void = { account, token in
        try KeychainTokenStore.save(token, forge: account.forge, name: account.name)
    }
    /// Whether a token is stored for (forge, account name).
    @ObservationIgnored var hasStoredToken: @Sendable (ForgeID, String) throws -> Bool = {
        try KeychainTokenStore.load(forge: $0, name: $1) != nil
    }
    @ObservationIgnored var deleteToken: (AccountConfig) -> Void = {
        KeychainTokenStore.delete(forge: $0.forge, name: $0.name)
    }
    /// Verifies a token against the account's scope. Injectable so tests
    /// never hit the network.
    @ObservationIgnored var verifyToken: (AccountConfig, String) async -> StatusLine = { account, token in
        await AccountsModel.liveVerify(account, token: token)
    }
    /// Fired after any successful token or config change.
    @ObservationIgnored var onChanged: (() -> Void)?

    // MARK: State

    private(set) var rows: [Row] = []
    /// Pasted-token text per account name.
    var tokenTexts: [String: String] = [:]

    /// The forges the add form offers, in fixed display order.
    let forgeOptions: [ForgeID] = [.github, .gitlab, .gitea, .forgejo]
    var newForge: ForgeID = .github
    var newName = ""
    var newScope = ""
    var newInstance = ""
    private(set) var addStatus = StatusLine(text: "")

    private static let storedText = "Token stored in your Keychain ✓ — paste a new one only to replace it."

    // MARK: Forge-specific add-form text

    /// The scope field's prompt: GitLab scopes nest.
    func scopePlaceholder(for forge: ForgeID) -> String {
        forge == .gitlab ? "group/subgroup or group/project" : "owner/name, or an org"
    }

    /// The instance field's prompt, or nil when the forge has no field
    /// (GitHub tokens work without one; GitLab defaults to gitlab.com).
    func instancePlaceholder(for forge: ForgeID) -> String? {
        switch forge {
        case .github: return nil
        case .gitea, .forgejo: return "https://gitea.example.com"
        case .gitlab: return "https://gitlab.com (optional)"
        }
    }

    /// Self-hosted forges need a server address before the account makes sense.
    func instanceRequired(for forge: ForgeID) -> Bool {
        forge == .gitea || forge == .forgejo
    }

    /// What the new account's token will need, shown as the form's hint.
    func requirements(for forge: ForgeID, scope: String, instance: String?) -> TokenRequirements {
        let scope = scope.trimmingCharacters(in: .whitespaces)
        let filled = (instance ?? "").trimmingCharacters(in: .whitespaces)
        switch forge {
        case .github:
            return TokenRequirements.github(scope: scope)
        case .gitea, .forgejo:
            return TokenRequirements.gitea(scope: scope, instance: filled.isEmpty ? nil : filled)
        case .gitlab:
            return TokenRequirements.gitlab(scope: scope, instance: filled.isEmpty ? nil : filled)
        }
    }

    // MARK: Loading

    /// Re-reads the accounts list and Keychain state (Keychain reads run off
    /// the main thread; they can block on a system prompt).
    func reload() {
        let accounts: [AccountConfig]
        do {
            // The forge cards above own each forge's conventional account.
            accounts = try AccountsConfigEditor.accounts(at: configURL).filter {
                !ForgeConnectionModel.ownsAccount($0)
            }
        } catch ConfigEditError.notFound {
            accounts = []
        } catch {
            Log.warn("config", "could not read accounts: \(error.localizedDescription)")
            accounts = []
        }
        let probe = hasStoredToken
        Task { [weak self] in
            let stored = await Task.detached {
                accounts.map { account in Result { try probe(account.forge, account.name) } }
            }
            .value
            self?.render(accounts: accounts, stored: stored)
        }
    }

    /// A failed Keychain probe shows its error on that account's row instead of
    /// "No token yet", so a locked keychain doesn't read as an unset account.
    private func render(accounts: [AccountConfig], stored: [Result<Bool, Error>]) {
        rows = zip(accounts, stored).map { account, probe in
            switch probe {
            case .success(let hasToken):
                return Row(
                    account: account, tokenStored: hasToken,
                    status: StatusLine(
                        text: hasToken ? Self.storedText : "No token yet — paste one to connect.",
                        style: hasToken ? .secondary : .warn))
            case .failure(let error):
                return Row(
                    account: account, tokenStored: false,
                    status: StatusLine(text: "Keychain error — \(error.localizedDescription)", style: .error))
            }
        }
        tokenTexts = tokenTexts.filter { name, _ in accounts.contains { $0.name == name } }
    }

    // MARK: Add / remove

    /// Adds the account described by the "new account" fields to config.yaml.
    func addAccount() {
        let name = newName.trimmingCharacters(in: .whitespaces).lowercased()
        let scope = newScope.trimmingCharacters(in: .whitespaces)
        let instance = newInstance.trimmingCharacters(in: .whitespaces)
        if instanceRequired(for: newForge), instance.isEmpty {
            addStatus = StatusLine(text: "Not added — enter the \(newForge.displayName) server address.", style: .error)
            return
        }
        // Only forges with a server address store one; GitHub ignores it, and
        // a blank GitLab instance means gitlab.com.
        let usesInstance = newForge != .github
        let account = AccountConfig(
            name: name, forge: newForge, scope: scope,
            instance: usesInstance && !instance.isEmpty ? instance : nil)
        do {
            try AccountsConfigEditor.add(account, to: configURL)
        } catch {
            addStatus = StatusLine(text: "Not added — \(error.localizedDescription)", style: .error)
            return
        }
        newName = ""
        newScope = ""
        newInstance = ""
        addStatus = StatusLine(text: "Added '\(name)' — paste its token below.", style: .ok)
        reload()
        onChanged?()
    }

    /// Removes an account from config.yaml and deletes its Keychain token.
    func removeAccount(_ name: String) {
        guard let row = rows.first(where: { $0.account.name == name }) else { return }
        do {
            try AccountsConfigEditor.remove(name: name, at: configURL)
        } catch {
            update(name) { $0.status = StatusLine(text: "Not removed — \(error.localizedDescription)", style: .error) }
            return
        }
        deleteToken(row.account)
        addStatus = StatusLine(text: "Removed '\(name)'.", style: .secondary)
        reload()
        onChanged?()
    }

    // MARK: Token

    /// Verifies the pasted token for the account, then stores it.
    func connect(_ name: String) {
        guard let row = rows.first(where: { $0.account.name == name }) else { return }
        let typed = (tokenTexts[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        update(name) {
            $0.checking = true
            $0.status = StatusLine(text: "Checking the token…")
        }
        Task { [weak self] in
            guard let self else { return }
            defer { self.update(name) { $0.checking = false } }
            let verdict = await self.verifyToken(row.account, typed)
            guard verdict.style == .ok else {
                self.update(name) { $0.status = verdict }
                return
            }
            do {
                try await self.saveToken(row.account, typed)
                self.tokenTexts[name] = nil
                self.update(name) {
                    $0.tokenStored = true
                    $0.status = verdict
                }
                self.onChanged?()
            } catch {
                self.update(name) {
                    $0.status = StatusLine(
                        text: "Couldn't save the token — \(error.localizedDescription)", style: .error)
                }
            }
        }
    }

    private func update(_ name: String, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.account.name == name }) else { return }
        change(&rows[index])
    }

    // MARK: Live verification

    static func liveVerify(_ account: AccountConfig, token: String) async -> StatusLine {
        let report = await TokenHealthCheck.account(account, token: token)
        return StatusLine(text: report.message, style: report.ok ? .ok : .error)
    }

    // MARK: Test hooks

    func setTokenTextForTesting(_ name: String, _ text: String) { tokenTexts[name] = text }
}
