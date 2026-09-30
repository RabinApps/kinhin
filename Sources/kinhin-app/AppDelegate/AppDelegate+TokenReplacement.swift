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
                try await client.perform { try $0.replaceToken(pat: token) }
                Log.info("app", "replaced GitHub token (daemon notified)")
            } else {
                Log.info("app", "replaced GitHub token (no engine running yet)")
            }
        case .gitea, .forgejo:
            // Gitea-family tokens belong to the primary account of that forge
            // (named "gitea"/"forgejo"), which routes through the account swap.
            let forge = forge
            try KeychainTokenStore.save(token, forge: forge)
            let accountName = forge == .gitea ? ForgeID.gitea.rawValue : ForgeID.forgejo.rawValue
            if let engine {
                await engine.replaceToken(account: accountName, token: token)
                Log.info("app", "replaced \(forge.rawValue) token (in-process engine)")
            } else if let client {
                try await client.perform { try $0.replaceAccountToken(account: accountName, token: token) }
                Log.info("app", "replaced \(forge.rawValue) token (daemon notified)")
            } else {
                Log.info("app", "replaced \(forge.rawValue) token (no engine running yet)")
            }
        case .gitlab:
            // GitLab has no legacy section: its token belongs to the account named "gitlab".
            try await notifyAccountTokenReplaced(
                account: AccountConfig(name: ForgeID.gitlab.rawValue, forge: .gitlab, scope: ""), token: token)
            return
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
            let name = account.name
            try await client.perform { try $0.replaceAccountToken(account: name, token: token) }
            Log.info("app", "replaced token for account '\(account.name)' (daemon notified)")
        } else {
            Log.info("app", "stored token for account '\(account.name)' (no engine running yet)")
        }
        await refresh()
    }
}
