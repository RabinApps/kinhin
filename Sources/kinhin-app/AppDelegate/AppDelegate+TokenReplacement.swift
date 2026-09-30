import AppKit
import KinhinKit

@MainActor
extension AppDelegate {
    /// Swap a stored provider token at runtime: save to the Keychain, then
    /// hand the new token to whichever process owns the engine (in-process
    /// engine, or the daemon over RPC) so the swap takes effect without a
    /// restart. Called from the Setup tab's Connect form.
    func notifyTokenReplaced(forge: ForgeID, token: String) async throws {
        // Every forge card's token lives under its primary account's item.
        try KeychainTokenStore.save(token, forge: forge, name: forge.rawValue)
        try await rotate(.forge(forge), token: token)
    }

    /// Same for a named `accounts:` entry: save to the Keychain under the
    /// account's own item, then hand the token to the engine (or daemon).
    func notifyAccountTokenReplaced(account: AccountConfig, token: String) async throws {
        try KeychainTokenStore.save(token, forge: account.forge, name: account.name)
        try await rotate(.account(account.name), token: token)
    }

    private func rotate(_ target: CredentialRotation.Target, token: String) async throws {
        if let backend {
            try await backend.rotate(target, token: token)
            Log.info("app", "replaced token for '\(target.accountName)' (\(backend.logName))")
        } else {
            Log.info("app", "stored token for '\(target.accountName)' (no engine running yet)")
        }
        await refresh()
    }
}
