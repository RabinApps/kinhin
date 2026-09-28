import Foundation
import KinhinKit

// MARK: - Config writes, deselect, test hooks

@MainActor
extension ForgeConnectionModel {
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
