import Foundation

/// Adds, updates and removes entries of the `accounts:` list in config.yaml.
/// Like the other editors it edits text (the rest of the file keeps its
/// comments and layout), re-validates through `ConfigLoader.parse`, and
/// writes only when the result is valid. The `accounts:` block itself is
/// rewritten whole. This is the editor for every forge account — GitHub,
/// GitLab, Gitea and Forgejo all live in the one list.
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
        try ConfigFileEdit.read(url)
    }

    private static func write(_ accounts: [AccountConfig], to url: URL) throws -> String {
        try ConfigFileEdit.apply(to: url) { original in
            try GeneralConfigEditor.replaceSectionToggle(
                "accounts", present: !accounts.isEmpty, in: original, newText: { sectionText(accounts) })
        }
    }

    static func sectionText(_ accounts: [AccountConfig]) -> String {
        var lines = ["accounts:"]
        for account in accounts {
            lines.append("  - name: \(YAMLText.quoted(account.name))")
            lines.append("    forge: \(account.forge.rawValue)")
            lines.append("    scope: \(YAMLText.quoted(account.scope))")
            if let instance = account.instance { lines.append("    instance: \(YAMLText.quoted(instance))") }
            if let labels = account.labels {
                lines.append("    labels: [\(labels.map(YAMLText.quoted).joined(separator: ", "))]")
            }
            if account.allowInsecureHTTP == true { lines.append("    allow_insecure_http: true") }
            if let scaleSet = account.scaleSet {
                lines.append("    scale_set:")
                lines.append("      name: \(YAMLText.quoted(scaleSet.name))")
                if let runnerGroup = scaleSet.runnerGroup {
                    lines.append("      runner_group: \(YAMLText.quoted(runnerGroup))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
