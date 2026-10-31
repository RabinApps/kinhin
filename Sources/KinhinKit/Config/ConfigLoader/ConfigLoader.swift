import Foundation
import Yams

/// Loads and validates `KinhinConfig`.
public struct ConfigLoader {
    public init() {}

    /// The GitHub repo value used to be carried by `repo:`; under the
    /// accounts schema there is no placeholder. Kept for the checklist's
    /// template wording only.
    public static let templateRepo = "your-org/your-repo"

    /// True when the parsed config carries no forge accounts yet (the
    /// starter-template state).
    static func isTemplate(_ cfg: KinhinConfig) -> Bool {
        cfg.accounts.isEmpty
    }

    /// The GitHub token the engine is built with. With GitHub configured it is
    /// the Keychain PAT; if that is missing but a Gitea forge is configured
    /// with its own token, an empty placeholder lets the fleet run on Gitea
    /// alone (GitHub then reports its problem instead of blocking startup).
    /// Gitea-only configs also get the placeholder. Nil when no configured
    /// forge has a usable token. Throws when the Keychain itself fails, so a
    /// locked or denied Keychain is reported as such instead of "no token".
    public static func engineToken(
        for cfg: KinhinConfig,
        loadAccount: (ForgeID, String) throws -> String? = { try KeychainTokenStore.load(forge: $0, name: $1) }
    ) throws -> String? {
        let anyAccountReady = try cfg.accounts.contains { try loadAccount($0.forge, $0.name) != nil }
        return anyAccountReady ? "" : nil
    }

    /// True when at least one forge is configured for real work.
    public static func hasAnyForge(_ cfg: KinhinConfig) -> Bool {
        !cfg.accounts.isEmpty
    }

    /// Creates the starter config on first run. Never overwrites: an existing
    /// file (template or hand-edited) is left alone. Returns true when a file
    /// was written.
    @discardableResult
    public static func createIfMissing(at url: URL = Paths.config) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return false }
        Paths.ensureSupportDirectories()
        do {
            try template().write(toFile: url.path, atomically: true, encoding: .utf8)
            return true
        } catch {
            // Auto-creation is a convenience; a failure here (permissions,
            // full disk) must never take the app down. The checklist will
            // still show "not created yet" with a repair action.
            return false
        }
    }

    public static func load(from url: URL = Paths.config) throws -> KinhinConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.notFound(url.path)
        }
        let yaml: String
        do {
            yaml = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigError.unreadable(url.path, reason: error.localizedDescription)
        }
        return try Self.parse(yaml)
    }

    public static func parse(_ yaml: String) throws -> KinhinConfig {
        let partial = try Self.decode(yaml)
        try rejectRemovedKeys(partial)
        try checkSchema(partial, yaml: yaml)

        var cfg = KinhinConfig.default
        // Every forge is an `accounts:` entry. A config with none is the
        // starter-template state: it parses (so editors and the checklist can
        // classify it) but `hasAnyForge` is false and the engine refuses to run.
        cfg.accounts = try parseAccounts(partial.accounts ?? [])
        cfg.labels = try parseLabels(partial.labels)
        try parseScaling(partial, into: &cfg)
        try parseVM(partial.vm, into: &cfg)
        try parseImageSettings(partial, into: &cfg)
        try parseToolchainSettings(partial, into: &cfg)
        cfg.container = try partial.container.map(parseContainer)
        cfg.docker = try partial.docker.map(parseDocker)
        if let runtimes = partial.runtimes {
            cfg.runtimes = try parseRuntimes(runtimes, container: cfg.container, docker: cfg.docker)
        }
        try parseReserve(partial.reserve, into: &cfg)
        if let healing = partial.healing { cfg.healing = try parseHealing(healing) }
        if let telemetry = partial.telemetry { cfg.telemetry = try parseTelemetry(telemetry) }
        try validateHostScopes(cfg)
        try validateEphemeralForges(cfg)
        try validateMinIdle(cfg)
        return cfg
    }

    /// Decodes the YAML into the all-optional shape, mapping YAML syntax and
    /// wrong-typed-value failures to a `ConfigError` that names the config key.
    static func decode(_ yaml: String) throws -> PartialConfig {
        do {
            return try YAMLDecoder().decode(PartialConfig.self, from: yaml)
        } catch let error as DecodingError {
            throw ConfigError.invalid(error.configDescription)
        } catch let error as YamlError {
            throw ConfigError.invalid("not valid YAML — \(error)")
        }
    }

    /// Host mode runs repo code unisolated on the Mac, and the host runner is
    /// registered at the account's scope: any workflow in that scope can ask for
    /// it by label, whatever the routes say. So with a host route configured every
    /// account must be scoped to a single repository, never a whole org, group,
    /// cluster or pool.
    private static func validateHostScopes(_ cfg: KinhinConfig) throws {
        guard cfg.hostRoutesConfigured else { return }
        for account in cfg.accounts where !account.isSingleRepositoryScope {
            throw ConfigError.invalid(
                "account '\(account.name)' (scope '\(account.scope)') would expose host mode to everything in that scope: "
                    + "the host runner registers at the account's scope, so any workflow there could run unisolated on your Mac. "
                    + "With a runtime 'host' route, give every account a single-repository scope (owner/name)")
        }
    }
}
