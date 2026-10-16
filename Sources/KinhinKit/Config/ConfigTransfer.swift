import Foundation

/// Moving a config from one Mac to another (`kinhin config export` / `import`).
///
/// The config holds no secrets: tokens stay in each Mac's Keychain and images are
/// baked per Mac, so a transfer is the YAML plus a short list of what the new Mac
/// still needs. Exports carry a `# kinhin export:` header that import strips, so
/// moving a config back and forth never stacks headers.
public enum ConfigTransfer {
    static let headerPrefix = "# kinhin export: "

    /// One account and whether this Mac already has its token.
    public struct AccountStatus: Equatable, Sendable {
        public var name: String
        public var forge: ForgeID
        public var tokenStored: Bool
    }

    /// What an import would do; `apply` carries it out.
    public struct ImportPlan: Equatable, Sendable {
        /// The YAML that would be written, without the export header.
        public var yaml: String
        public var configURL: URL
        /// A config already exists at `configURL` (it is backed up first).
        public var replacesExisting: Bool
        /// The incoming config is byte-for-byte the current one.
        public var unchanged: Bool
        public var accounts: [AccountStatus]
        /// Settings that point at this Mac's file system and do not resolve here.
        public var warnings: [String]

        public var backupURL: URL { configURL.appendingPathExtension("bak") }
    }

    /// The export: the validated config with a header naming where it came from.
    /// Throws the loader's error for a config that would not import cleanly.
    public static func export(configURL: URL = Paths.config, host: String, date: Date = Date()) throws -> String {
        _ = try ConfigLoader.load(from: configURL)
        let yaml = stripHeader(try String(contentsOf: configURL, encoding: .utf8))
        let stamp = ISO8601DateFormatter().string(from: date)
        let header = [
            "\(headerPrefix)from \(host) at \(stamp).",
            "\(headerPrefix)tokens are not included; they stay in that Mac's Keychain.",
            "\(headerPrefix)on the other Mac run: kinhin config import <this file>",
        ]
        return header.joined(separator: "\n") + "\n" + yaml
    }

    /// Validates `incoming` and works out what importing it into `configURL`
    /// would change. Throws the loader's error when the YAML is not a usable config,
    /// and the read error when an existing config cannot be read (it would
    /// otherwise be replaced without a backup). A Keychain that cannot be
    /// checked is a warning, not "no token".
    public static func plan(
        incoming: String,
        configURL: URL = Paths.config,
        tokenStored: (ForgeID, String) throws -> Bool = defaultTokenStored,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> ImportPlan {
        let yaml = stripHeader(incoming)
        let config = try ConfigLoader.parse(yaml)
        let current: String? =
            FileManager.default.fileExists(atPath: configURL.path)
            ? try String(contentsOf: configURL, encoding: .utf8) : nil
        var warnings: [String] = []
        if let tart = config.tartPath, !fileExists(tart) {
            warnings.append("tart_path \(tart) does not exist on this Mac; fix or remove it after the import")
        }
        var accounts: [AccountStatus] = []
        for account in config.accounts {
            var stored = false
            do {
                stored = try tokenStored(account.forge, account.name)
            } catch {
                warnings.append(
                    "could not check the Keychain for account \(account.name): \(error.localizedDescription)")
            }
            accounts.append(AccountStatus(name: account.name, forge: account.forge, tokenStored: stored))
        }
        return ImportPlan(
            yaml: yaml,
            configURL: configURL,
            replacesExisting: current != nil,
            unchanged: current == yaml,
            accounts: accounts,
            warnings: warnings)
    }

    /// Writes the plan: the current config (if any) is kept at `backupURL`, and
    /// the new one is private like every other support file.
    public static func apply(_ plan: ImportPlan) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: plan.configURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if plan.replacesExisting {
            // No earlier backup is the usual case; one that cannot go makes copyItem throw below.
            try? fm.removeItem(at: plan.backupURL)
            try fm.copyItem(at: plan.configURL, to: plan.backupURL)
        }
        try Paths.writePrivateFile(Data(plan.yaml.utf8), to: plan.configURL)
    }

    /// Drops the leading `# kinhin export:` lines an earlier export added.
    static func stripHeader(_ yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")[...]
        while let first = lines.first, first.hasPrefix(headerPrefix) { lines = lines.dropFirst() }
        return lines.joined(separator: "\n")
    }

    public static func defaultTokenStored(_ forge: ForgeID, _ name: String) throws -> Bool {
        try KeychainTokenStore.load(forge: forge, name: name) != nil
    }
}
