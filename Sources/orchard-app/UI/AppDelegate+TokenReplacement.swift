import AppKit
import OrchardKit

@MainActor
extension AppDelegate {
    /// Opens the token settings form (one card per provider: GitHub, Gitea).
    /// Menu item title and selector are unchanged.
    @objc func replaceTokenClicked() {
        openTokenSettings(focusing: .github)
    }

    /// Shared opener for the menu item and the setup checklist's token rows
    /// (which pre-focus the provider they refer to).
    func openTokenSettings(focusing forge: ForgeID) {
        if tokenSettingsController == nil {
            let controller = TokenSettingsWindowController()
            controller.onSaved = { [weak self] forge, token in
                try await self?.notifyTokenReplaced(forge: forge, token: token)
            }
            tokenSettingsController = controller
        }
        tokenSettingsController?.initialFocus = forge
        tokenSettingsController?.showWindow(nil)
        tokenSettingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Swap a stored provider token at runtime: save to the Keychain, then
    /// hand the new token to whichever process owns the engine (in-process
    /// engine, or the daemon over RPC) so the swap takes effect without a
    /// restart. Called from the token settings form.
    func notifyTokenReplaced(forge: ForgeID, token: String) async throws {
        switch forge {
        case .github:
            try KeychainTokenStore.save(token)
            if let engine {
                await engine.replaceCredentials(pat: token)
                Log.info("app", "replaced GitHub token (in-process engine)")
            } else if let client {
                try client.replaceToken(pat: token)
                Log.info("app", "replaced GitHub token (daemon notified)")
            } else {
                Log.info("app", "replaced GitHub token (no engine running yet)")
            }
        case .gitea:
            try KeychainTokenStore.save(token, forge: .gitea)
            if let engine {
                await engine.replaceGiteaToken(token)
                Log.info("app", "replaced Gitea token (in-process engine)")
            } else if let client {
                try client.replaceGiteaToken(token)
                Log.info("app", "replaced Gitea token (daemon notified)")
            } else {
                Log.info("app", "replaced Gitea token (no engine running yet)")
            }
        }
        await refresh()
    }
}
