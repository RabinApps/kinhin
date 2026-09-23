import AppKit
import OrchardKit

@MainActor
extension AppDelegate {
    /// Swap the stored PAT at runtime: save to Keychain, then hand the new
    /// token to whichever process owns the engine (in-process engine, or the
    /// daemon over RPC) so the swap takes effect without a restart.
    @objc func replaceTokenClicked() {
        let alert = NSAlert()
        alert.messageText = "Replace GitHub Access Token"
        alert.informativeText = "The new token is stored in your Keychain and takes effect immediately — no restart needed."
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "ghp_…"
        alert.accessoryView = input
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty else { return }

        let pat = input.stringValue
        Task {
            do {
                try KeychainTokenStore.save(pat)
                if let engine {
                    await engine.replaceCredentials(pat: pat)
                    Log.info("app", "replaced GitHub token (in-process engine)")
                } else if let client {
                    try client.replaceToken(pat: pat)
                    Log.info("app", "replaced GitHub token (daemon notified)")
                } else {
                    Log.info("app", "replaced GitHub token (no engine running yet)")
                }
                await refresh()
            } catch {
                Log.error("app", "token replacement failed: \(error.localizedDescription)")
                let failure = NSAlert()
                failure.alertStyle = .critical
                failure.messageText = "Could not replace token"
                failure.informativeText = error.localizedDescription
                failure.runModal()
            }
        }
    }
}
