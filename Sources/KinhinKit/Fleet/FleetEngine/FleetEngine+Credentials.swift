import Foundation

// FleetEngine — token swaps. Every forge is an accounts: entry and attaches
// through the unified account path (FleetEngine+Accounts.swift).
extension FleetEngine {
    /// Swap the primary GitHub account's PAT: re-attaches its forge with a
    /// client built from the new token and drops its cached registration
    /// token (minted under the old token's authority). Safe to call while
    /// running — the next reconcile/registration uses the new credentials;
    /// in-flight VMs are untouched.
    public func replaceCredentials(pat: String) async {
        guard let primary = config.primaryGitHub else {
            Log.warn("engine", "GitHub token replaced but GitHub is not configured — ignoring")
            return
        }
        await attach(account: primary, token: pat, verify: false)
        Log.info("engine", "GitHub credentials replaced (scope: \(primary.scope))")
    }

    /// Reads a token from the Keychain. When there is none, the reason goes to
    /// the log and `lastError`: `missing` for a token that was never stored, the
    /// Keychain's own error when it could not be read (a locked keychain must
    /// not read as "run kinhin auth set").
    func storedToken(missing: String, load: () throws -> String?) async -> String? {
        let message: String
        do {
            if let token = try load() { return token }
            message = missing
        } catch {
            message = error.localizedDescription
        }
        Log.error("engine", message)
        await statusBox.modify { $0.setAlert("credentials", message) }
        return nil
    }

}
