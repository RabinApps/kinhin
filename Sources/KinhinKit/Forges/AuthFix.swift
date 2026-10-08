import Foundation

/// The remediation text for "this account's token is missing or rejected", in
/// one place so every message names the same command.
///
/// `kinhin auth set --account NAME` works for every forge. Only a GitHub token
/// with no account to name falls back to the bare `kinhin auth set` (the
/// primary GitHub PAT). The `--gitea` shortcut is deliberately never
/// suggested: it stores the Gitea item, which a Forgejo account does not read.
public enum AuthFix {
    /// The command that stores a token for `account` (nil when the caller only
    /// knows the forge, which prints the `NAME` placeholder).
    public static func command(forge: ForgeID, account: String?) -> String {
        if let account, !account.isEmpty { return "kinhin auth set --account \(account)" }
        return forge == .github ? "kinhin auth set" : "kinhin auth set --account NAME"
    }
}
