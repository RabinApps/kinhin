import AppKit
import KinhinKit

@MainActor
extension AppDelegate {
    /// Opens the Setup tab, where tokens are entered (menu item title and
    /// selector are unchanged).
    @objc func replaceTokenClicked() {
        openTokenSettings(focusing: .github)
    }

    /// Shared opener for the token menu item and any "add a token" prompt.
    func openTokenSettings(focusing forge: ForgeID) {
        openMainWindow()
        mainController?.showSetup()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Swap a stored provider token at runtime: save to the Keychain, then
    /// hand the new token to whichever process owns the engine (in-process
    /// engine, or the daemon over RPC) so the swap takes effect without a
    /// restart. Called from the Setup tab's Connect form.
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
        case .forgejo:
            try KeychainTokenStore.save(token, forge: .forgejo)
            if let engine {
                await engine.replaceForgejoToken(token)
                Log.info("app", "replaced Forgejo token (in-process engine)")
            } else if let client {
                try client.replaceForgejoToken(token)
                Log.info("app", "replaced Forgejo token (daemon notified)")
            } else {
                Log.info("app", "replaced Forgejo token (no engine running yet)")
            }
        }
        await refresh()
    }

    /// Same for a named `accounts:` entry: save to the Keychain under the
    /// account's own item, then hand the token to the engine (or daemon).
    func notifyAccountTokenReplaced(account: AccountConfig, token: String) async throws {
        try KeychainTokenStore.save(token, forge: account.forge, name: account.name)
        if let engine {
            await engine.replaceToken(account: account.name, token: token)
            Log.info("app", "replaced token for account '\(account.name)' (in-process engine)")
        } else if let client {
            try client.replaceAccountToken(account: account.name, token: token)
            Log.info("app", "replaced token for account '\(account.name)' (daemon notified)")
        } else {
            Log.info("app", "stored token for account '\(account.name)' (no engine running yet)")
        }
        await refresh()
    }
}
