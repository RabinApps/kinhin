import Foundation

/// Hands a freshly stored token to whichever process runs the engine (the
/// in-process engine, or the daemon over RPC), so the running fleet uses it
/// without a restart. The CLI's `auth set` and the app's Connect form both
/// route through here: one rule for which swap a token needs.
public enum CredentialRotation {
    /// Whose token changed: a forge's primary account (`auth set --gitea`,
    /// a Connect card) or a named `accounts:` entry.
    public enum Target: Sendable, Equatable {
        case forge(ForgeID)
        case account(String)

        /// The `accounts:` name the token belongs to. A forge's primary
        /// account carries the forge's conventional name.
        public var accountName: String {
            switch self {
            case .forge(let forge): return forge.rawValue
            case .account(let name): return name
            }
        }
    }

    /// Swap the token in an in-process engine.
    public static func apply(_ target: Target, token: String, to engine: FleetEngine) async {
        if target == .forge(.github) {
            await engine.replaceCredentials(pat: token)
        } else {
            await engine.replaceToken(account: target.accountName, token: token)
        }
    }

    /// Ask a running daemon to swap the token (already in the Keychain).
    public static func notify(_ target: Target, token: String, daemon client: RPCClient) throws {
        if target == .forge(.github) {
            try client.replaceToken(pat: token)
        } else {
            try client.replaceAccountToken(account: target.accountName, token: token)
        }
    }
}
