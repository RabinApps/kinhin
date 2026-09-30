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
            case .github, .gitea, .forgejo, .gitlab:
                let instanceValue = instanceIfAny
                guard scopeValue != lastWrittenScope || instanceValue != lastWrittenInstanceIfAny else { return }
                var account = AccountConfig(name: accountName, forge: forge, scope: scopeValue)
                account.instance = instanceValue
                if try AccountsConfigEditor.accounts(at: configURL).contains(where: {
                    $0.name == accountName
                }) {
                    try AccountsConfigEditor.update(account, at: configURL)
                } else {
                    try AccountsConfigEditor.add(account, to: configURL)
                    if let fresh = try AccountsConfigEditor.accounts(at: configURL).first(where: {
                        $0.name == accountName
                    }) {
                        account = fresh
                    }
                }
                lastWrittenScope = scopeValue
                lastWrittenInstance = instanceValue ?? ""
                connected = tokenStored
                status =
                    forge == .github
                    ? Line(text: "Now serving \(scopeValue) ✓", style: .ok)
                    : Line(text: "Now serving \(scopeValue) on \(forge.displayName) ✓", style: .ok)
                onChanged?()
                if forge == .github {
                    // Now that there is a scope, check the token can manage its runners.
                    Task { [weak self] in await self?.verifyPermission(scope: scopeValue, token: nil) }
                }
            }
        } catch {
            status = .notSaved(error)
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
        tokenStored || !lastWrittenScope.isEmpty || !lastWrittenInstance.isEmpty
    }

    /// Removes the forge's config entry and Keychain token. A failed config
    /// write shows on the card's status line and rethrows, so the caller can
    /// keep the card open for a retry instead of half-removing the forge.
    func deselect() throws {
        do {
            try AccountsConfigEditor.remove(name: accountName, at: configURL)
        } catch ConfigEditError.unsupported {
            // No account entry (a token-only connect): nothing to remove.
        } catch {
            status = Line(text: "Couldn't remove — \(error.localizedDescription)", style: .error)
            throw error
        }
        deleteToken()
        tokenStored = false
        connected = false
        lastWrittenScope = ""
        lastWrittenInstance = ""
        status = Line(text: "Not connected yet.", style: .warn)
        onChanged?()
    }

    // MARK: Test hooks

    func show(_ line: Line) { status = line }

    func markTokenStoredForTesting(_ stored: Bool) {
        tokenStored = stored
        connected =
            stored && Self.countsAsConnected(forge: forge, scope: lastWrittenScope, instance: lastWrittenInstance)
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
