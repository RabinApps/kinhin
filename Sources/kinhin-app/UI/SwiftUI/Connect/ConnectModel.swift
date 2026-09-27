import Foundation
import KinhinKit
import Observation

/// State and actions behind the Connect form. A multi-select row of forge
/// chips ("Where does your code live?") decides which cards are shown; every
/// selected forge gets one uniform `ForgeConnectionModel` card. Used by both
/// the onboarding wizard and the Setup tab, so the same setting is never
/// entered twice.
///
/// Deselecting a forge with saved config or a token asks for confirmation
/// (`pendingDeselect`) before removing its account and token.
@MainActor
@Observable
final class ConnectModel {
    /// The forges the selector offers, in fixed display order.
    static let allForges: [ForgeID] = [.github, .gitlab, .gitea, .forgejo]

    let accounts = AccountsModel()

    // MARK: Injectable seams (forwarded to every card)

    /// Persists a token (and live-swaps it into a running engine). Defaults
    /// to a plain Keychain save; the app injects the live-swap version.
    @ObservationIgnored var saveToken: (ForgeID, String) async throws -> Void = { forge, token in
        try KeychainTokenStore.save(token, forge: forge)
    }
    /// The config file this form edits (tests point it at a scratch file).
    var configURL: URL = Paths.config {
        didSet {
            accounts.configURL = configURL
            for forge in ForgeID.allCases { card(for: forge)?.configURL = configURL }
        }
    }
    /// Whether a token is stored for a forge (tests stub this out so they
    /// never touch the real Keychain).
    @ObservationIgnored var hasStoredToken: @Sendable (ForgeID) throws -> Bool = {
        try KeychainTokenStore.load(forge: $0) != nil
    }
    /// Deletes the stored token when a forge is deselected.
    @ObservationIgnored var deleteToken: (ForgeID) -> Void = {
        KeychainTokenStore.delete(forge: $0)
    }
    /// Loads the stored token (for listing what it can see).
    @ObservationIgnored var loadToken: @Sendable (ForgeID) throws -> String? = {
        try KeychainTokenStore.load(forge: $0)
    }
    /// Fired after any successful token or config change.
    @ObservationIgnored var onChanged: (() -> Void)? {
        didSet { accounts.onChanged = onChanged }
    }

    // MARK: Selection

    /// The forges whose cards are shown.
    private(set) var selected: Set<ForgeID> = []
    /// A deselect awaiting confirmation (forge with saved state only).
    private(set) var pendingDeselect: ForgeID?

    private(set) var cards: [ForgeID: ForgeConnectionModel] = [:]

    var isConnected: Bool {
        selected.contains { card(for: $0)?.connected == true } || accounts.rows.contains { $0.tokenStored }
    }

    init() {}

    /// The card for a forge, creating it (and selecting it) on first access.
    /// Loading uses `knownCards` instead: it must not select anything the
    /// user never picked.
    func card(for forge: ForgeID) -> ForgeConnectionModel? {
        guard let card = cards[forge] else {
            guard selected.contains(forge) else { return nil }
            return makeCard(forge)
        }
        return card
    }

    private func makeCard(_ forge: ForgeID) -> ForgeConnectionModel {
        let card = ForgeConnectionModel(forge: forge)
        card.configURL = configURL
        card.saveToken = { [saveToken, forge] token in try await saveToken(forge, token) }
        card.hasStoredToken = { [hasStoredToken, forge] in try hasStoredToken(forge) }
        card.loadToken = { [loadToken, forge] in try loadToken(forge) }
        card.deleteToken = { [deleteToken, forge] in deleteToken(forge) }
        card.checkPermission = { [weak self] scope, token in
            await self?.checkPermission(scope, token)
        }
        card.onChanged = { [weak self] in self?.onChanged?() }
        cards[forge] = card
        card.reload()
        return card
    }

    /// The GitHub runner-management probe shared by every card (only
    /// GitHub's card installs it).
    @ObservationIgnored var checkPermission:
        (_ scope: String, _ token: String?) async -> OrgPermissionProbe
            .Report? = {
                scope, token in
                let resolved: String?
                do {
                    resolved =
                        if let token { token } else {
                            try await Task.detached { try KeychainTokenStore.load(forge: .github) }.value
                        }
                } catch {
                    return OrgPermissionProbe.Report(ok: false, message: error.localizedDescription)
                }
                guard let resolved, !scope.isEmpty else { return nil }
                return await OrgPermissionProbe.verify(
                    github: GitHubClient(credentials: GitHubCredentials(token: resolved, scope: scope)), scope: scope)
            }

    // MARK: Selector

    func isSelected(_ forge: ForgeID) -> Bool { selected.contains(forge) }

    /// Toggles a forge's chip. Selecting creates (and reloads) the card;
    /// deselecting a forge with saved state stages `pendingDeselect` so the
    /// view can confirm before anything is removed.
    func setSelected(_ on: Bool, for forge: ForgeID) {
        if on {
            pendingDeselect = nil
            guard cards[forge] == nil else {
                selected.insert(forge)
                return
            }
            selected.insert(forge)
            makeCard(forge)
        } else {
            selected.remove(forge)
            if let card = cards[forge], card.hasCommittedState {
                pendingDeselect = forge
                selected.insert(forge)  // keep the card until confirmed
            } else {
                cards[forge] = nil  // nothing was saved; just hide the card
            }
        }
        onChanged?()
    }

    /// Confirms a pending deselect: removes the forge's config entry and
    /// token (the card's `deselect`), then closes its card.
    func confirmDeselect() {
        guard let forge = pendingDeselect else { return }
        pendingDeselect = nil
        if let card = cards[forge] {
            try? card.deselect()  // failed writes surface on the card's status
        }
        cards[forge] = nil
        selected.remove(forge)
        onChanged?()
    }

    /// Cancels a pending deselect (the user backed out).
    func cancelDeselect() {
        pendingDeselect = nil
    }

    // MARK: Loading

    /// Re-reads config + Keychain and refreshes the selection and every card.
    func reload() {
        accounts.reload()
        let snapshot = ConfigStore.snapshotOrLog(at: configURL)
        Task { [weak self] in
            guard let self else { return }
            let probe = self.hasStoredToken
            let tokens = await Task.detached {
                ForgeID.allCases.map { forge in Result { try probe(forge) } }
            }.value
            self.render(snapshot: snapshot, tokens: tokens)
        }
    }

    private func render(snapshot: GeneralConfigEditor.Snapshot?, tokens: [Result<Bool, Error>]) {
        func stored(_ forge: ForgeID) -> Bool {
            guard let index = ForgeID.allCases.firstIndex(of: forge), index < tokens.count else { return false }
            return (try? tokens[index].get()) ?? false
        }

        var configured: Set<ForgeID> = []
        let repo = snapshot?.repo ?? ""
        if stored(.github) || (!repo.isEmpty && repo != ConfigLoader.templateRepo) {
            configured.insert(.github)
        }
        if stored(.gitlab) || ForgeConnectionModel.configuredGitLabAccount(at: configURL) != nil {
            configured.insert(.gitlab)
        }
        if stored(.gitea) || snapshot?.gitea != nil {
            configured.insert(.gitea)
        }
        if stored(.forgejo) {
            configured.insert(.forgejo)
        }

        selected = configured
        pendingDeselect = nil
        for forge in ForgeID.allCases where !configured.contains(forge) {
            cards[forge] = nil  // a deselected forge's card goes away
        }
        for forge in ForgeID.allCases where configured.contains(forge) {
            if let card = cards[forge] {
                card.reload()
            } else {
                makeCard(forge)
            }
        }
    }

    // MARK: Test hooks

    /// Marks tokens stored without touching the Keychain (tests).
    func markTokensStoredForTesting(_ stored: Set<ForgeID>) {
        for forge in ForgeID.allCases {
            card(for: forge)?.markTokenStoredForTesting(stored.contains(forge))
        }
    }

    func selectForTesting(_ forges: Set<ForgeID>) {
        for forge in forges where !selected.contains(forge) {
            setSelected(true, for: forge)
        }
    }
}
