import Foundation
import KinhinKit
import Observation

/// State and actions behind the "More accounts" section of the Connect form:
/// any number of extra GitHub or Gitea accounts, each with its own scope and
/// Keychain token. (The two top-level cards keep the original `repo:` and
/// `gitea:` accounts.) Config writes go through `AccountsConfigEditor`.
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

    var newForge: ForgeID = .github
    var newName = ""
    var newScope = ""
    var newInstance = ""
    private(set) var addStatus = StatusLine(text: "")

    private static let storedText = "Token stored in your Keychain ✓ — paste a new one only to replace it."

    // MARK: Loading

    /// Re-reads the accounts list and Keychain state (Keychain reads run off
    /// the main thread; they can block on a system prompt).
    func reload() {
        let accounts: [AccountConfig]
        do {
            accounts = try AccountsConfigEditor.accounts(at: configURL)
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
        let account = AccountConfig(
            name: name, forge: newForge, scope: scope, instance: newForge == .gitea ? instance : nil)
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
        switch account.forge {
        case .github:
            let client = GitHubClient(credentials: GitHubCredentials(token: token, scope: account.scope))
            let report = await OrgPermissionProbe.verify(github: client, scope: account.scope)
            return StatusLine(text: report.message, style: report.ok ? .ok : .error)
        case .gitea, .forgejo:
            guard let instance = account.instance else {
                return StatusLine(text: "This account has no server address in config.yaml.", style: .error)
            }
            let report = await TokenHealthCheck.gitea(
                token: token, config: KinhinConfig.GiteaForgeConfig(instance: instance, scope: account.scope))
            return StatusLine(text: report.message, style: report.ok ? .ok : .error)
        case .gitlab:
            let report = await TokenHealthCheck.gitlab(token: token, scope: account.scope, instance: account.instance)
            return StatusLine(text: report.message, style: report.ok ? .ok : .error)
        }
    }

    // MARK: Test hooks

    func setTokenTextForTesting(_ name: String, _ text: String) { tokenTexts[name] = text }
}
