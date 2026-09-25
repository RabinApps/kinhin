import Foundation

/// Adds, updates and removes entries of the `accounts:` list in config.yaml.
/// Like the other editors it edits text (the rest of the file keeps its
/// comments and layout), re-validates through `ConfigLoader.parse`, and
/// writes only when the result is valid. The `accounts:` block itself is
/// rewritten whole. The legacy `repo:` / `gitea:` accounts are edited by
/// `GeneralConfigEditor`.
public enum AccountsConfigEditor {
    /// The explicit accounts in the file at `url`.
    public static func accounts(at url: URL = Paths.config) throws -> [AccountConfig] {
        try ConfigLoader.parse(try read(url)).accounts
    }

    /// Append an account. Fails when the name is taken or the entry is invalid.
    @discardableResult
    public static func add(_ account: AccountConfig, to url: URL = Paths.config) throws -> String {
        let current = try accounts(at: url)
        if current.contains(where: { $0.name == account.name }) {
            throw ConfigEditError.validation("an account named '\(account.name)' already exists")
        }
        return try write(current + [account], to: url)
    }

    /// Replace the account with the same name.
    @discardableResult
    public static func update(_ account: AccountConfig, at url: URL = Paths.config) throws -> String {
        var current = try accounts(at: url)
        guard let index = current.firstIndex(where: { $0.name == account.name }) else {
            throw ConfigEditError.unsupported("no account named '\(account.name)' in config.yaml")
        }
        current[index] = account
        return try write(current, to: url)
    }

    /// Drop the account with this name.
    @discardableResult
    public static func remove(name: String, at url: URL = Paths.config) throws -> String {
        let current = try accounts(at: url)
        guard current.contains(where: { $0.name == name }) else {
            throw ConfigEditError.unsupported("no account named '\(name)' in config.yaml")
        }
        return try write(current.filter { $0.name != name }, to: url)
    }

    // MARK: - Writing

    private static func read(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigEditError.notFound(url.path)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func write(_ accounts: [AccountConfig], to url: URL) throws -> String {
        let original = try read(url)
        let updated = try GeneralConfigEditor.replaceSectionToggle(
            "accounts", present: !accounts.isEmpty, in: original, newText: { sectionText(accounts) })
        do {
            _ = try ConfigLoader.parse(updated)
        } catch {
            throw ConfigEditError.validation(error.localizedDescription)
        }
        try updated.write(toFile: url.path, atomically: true, encoding: .utf8)
        return updated
    }

    static func sectionText(_ accounts: [AccountConfig]) -> String {
        var lines = ["accounts:"]
        for account in accounts {
            lines.append("  - name: \(quote(account.name))")
            lines.append("    forge: \(account.forge.rawValue)")
            lines.append("    scope: \(quote(account.scope))")
            if let instance = account.instance { lines.append("    instance: \(quote(instance))") }
            if let labels = account.labels {
                lines.append("    labels: [\(labels.map(quote).joined(separator: ", "))]")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func quote(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
