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
final class ConnectModel: ConfigFormModel {
    /// The forges the selector offers, in `ForgeID`'s declaration order.
    static let allForges = ForgeID.allCases

    let accounts = AccountsModel()

    // MARK: - Injectable seams (forwarded to every card)

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
    {
        didSet { accounts.hasStoredToken = { [hasStoredToken] forge, _ in try hasStoredToken(forge) } }
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

    // MARK: - Selection

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

    // MARK: - Selector

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
            _ = makeCard(forge)
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

    /// Confirms the removal shown by the alert: deletes the forge's config
    /// entry and Keychain token, then closes its card. `forge` is captured
    /// when the alert is presented, because the dismissal binding can clear
    /// `pendingDeselect` before the button action runs. A failed removal
    /// keeps the card open with the error on its status line so it can be
    /// retried — nothing is half-removed.
    func confirmDeselect(_ forge: ForgeID?) {
        guard let forge, selected.contains(forge) else { return }
        pendingDeselect = nil
        if let card = cards[forge] {
            do {
                try card.deselect()
            } catch {
                return  // the card's status line shows the error
            }
        }
        cards[forge] = nil
        selected.remove(forge)
        onChanged?()
    }

    /// Confirms the currently staged deselect (tests and programmatic use).
    func confirmDeselect() {
        confirmDeselect(pendingDeselect)
    }

    /// Cancels a pending deselect (the user backed out).
    func cancelDeselect() {
        pendingDeselect = nil
    }

    /// The deselect entry point the view uses (forge chips and each card's
    /// Remove button). A forge with saved config or token stages
    /// `pendingDeselect` so the view can confirm; one with nothing saved is
    /// hidden right away.
    func requestDeselect(_ forge: ForgeID) {
        guard isSelected(forge) else { return }
        setSelected(false, for: forge)
    }

    // MARK: - Loading

    /// Re-reads config + Keychain and refreshes the selection and every card.
    func reload() {
        accounts.reload()
        Task { [weak self] in
            guard let self else { return }
            let probe = self.hasStoredToken
            let tokens = await Task.detached {
                ForgeID.allCases.map { forge in Result { try probe(forge) } }
            }.value
            self.render(tokens: tokens)
        }
    }

    private func render(tokens: [Result<Bool, Error>]) {
        func stored(_ forge: ForgeID) -> Bool {
            guard let index = ForgeID.allCases.firstIndex(of: forge), index < tokens.count else { return false }
            // A failed Keychain probe shows as "token missing" — the form is
            // still fully usable; a redaction-safe warning keeps it visible.
            do {
                return try tokens[index].get()
            } catch {
                Log.warn("app", "\(forge.rawValue) token probe failed: \(error.localizedDescription)")
                return false
            }
        }

        var configured: Set<ForgeID> = []
        // `try?` is safe: an unreadable config surfaces through the card's
        // own reload path; this only decides which cards to show. Only a
        // card-owned account selects its card (others are "More accounts").
        let configuredForges = Set(
            ((try? AccountsConfigEditor.accounts(at: configURL)) ?? [])
                .filter(ForgeConnectionModel.ownsAccount).map(\.forge))
        for forge in ForgeID.allCases where stored(forge) || configuredForges.contains(forge) {
            configured.insert(forge)
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
                _ = makeCard(forge)
            }
        }
    }

    // MARK: - Test hooks

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
