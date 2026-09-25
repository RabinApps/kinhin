import Foundation
import KinhinKit

/// Injectable dependencies for the auth command. `.live` talks to the real
/// Keychain, stdin, forge APIs, and daemon socket; tests substitute recording
/// doubles so token flows never touch the login Keychain or the network.
///
/// The `fail`/`exit` hooks are throwing `Never`-returning functions: live
/// behavior terminates the process, tests throw a catchable error and assert
/// on the code/message instead.
struct AuthEnvironment {
    var save: (String, ForgeID) throws -> Void
    /// Returns the stored token for the forge, or nil when none is stored.
    var load: (ForgeID) -> String?
    var delete: (ForgeID) -> Void
    /// Interactive read for `auth set` without --token (raw stdin line).
    var readToken: () -> String?
    /// `auth status` probe — throws when the forge rejects the token.
    var checkGitHub: (GitHubCredentials) async throws -> Void
    var checkGitea: (GiteaCredentials) async throws -> Void
    var loadConfig: () -> KinhinConfig
    /// Best-effort live-swap notification to a running daemon.
    var notifyDaemon: (String, ForgeID) -> Void
    /// stderr `kinhin: <message>` + exit 1.
    var fail: (String) throws -> Never
    /// Bare exit (stdout already carries the user-facing line).
    var exit: (Int) throws -> Never
    /// Named-account token access (`--account NAME`, `auth add/remove`).
    var saveAccount: (String, ForgeID, String) throws -> Void = { try KeychainTokenStore.save($0, forge: $1, name: $2) }
    var loadAccount: (ForgeID, String) -> String? = { KeychainTokenStore.load(forge: $0, name: $1) }
    var deleteAccount: (ForgeID, String) -> Void = { KeychainTokenStore.delete(forge: $0, name: $1) }
    /// Best-effort live-swap notification for a named account: (account, token).
    var notifyDaemonAccount: (String, String) -> Void = { account, token in
        notifyDaemonAccountTokenReplaced(account: account, token: token)
    }
    /// The config file `auth add/remove` edit.
    var configURL: URL = Paths.config
    /// Config fixture for `auth status --json`: nil property → read the live
    /// file (tolerant of a missing one); a set value → use it instead, so
    /// tests never touch the developer's real config.
    var jsonConfig: KinhinConfig?? = nil

    /// Static so `live`'s initializer can reference them without touching
    /// instance state (Swift forbids instance members in property initializers).
    static func fail(_ message: String) -> Never {
        kinhin.fail(message, exit: .auth)
    }

    static func exit(_ code: Int) -> Never {
        Foundation.exit(Int32(code))
    }

    /// `auth status --json` works without a config file — the report's
    /// job is to *report* what's missing, not die on it.
    static func loadConfigTolerant() -> KinhinConfig? {
        try? ConfigLoader.load()
    }

    static let live = AuthEnvironment(
        save: { try KeychainTokenStore.save($0, forge: $1) },
        load: { KeychainTokenStore.load(forge: $0) },
        delete: { KeychainTokenStore.delete(forge: $0) },
        readToken: { String(data: FileHandle.standardInput.availableData, encoding: .utf8) },
        checkGitHub: { credentials in _ = try await GitHubClient(credentials: credentials).listRunners() },
        checkGitea: { credentials in _ = try await GiteaClient(credentials: credentials).fetchRegistrationToken() },
        loadConfig: { loadConfigOrExit() },
        notifyDaemon: { token, forge in
            if forge == .gitea {
                notifyDaemonGiteaTokenReplaced(token)
            } else {
                notifyDaemonTokenReplaced(token)
            }
        },
        fail: { Self.fail($0) },
        exit: { Self.exit($0) }
    )
}

enum AuthCommand {
    /// Builds, prints, and returns the machine-readable status document.
    /// Static — no network probes, tolerant of a missing config file.
    static func emitStatusJSON(environment: AuthEnvironment) throws -> (report: AuthStatusReport, data: Data) {
        let report = AuthStatusReporter.report(
            config: environment.jsonConfig ?? AuthEnvironment.loadConfigTolerant(),
            load: environment.load,
            loadAccount: environment.loadAccount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        print(String(decoding: data, as: UTF8.self))
        return (report, data)
    }

    /// The permissions the token for `forge` needs, for the configured scope
    /// (both repo and org cases when there is no config yet).
    static func requirements(for forge: ForgeID, config: KinhinConfig?) -> TokenRequirements {
        if forge == .gitea {
            return TokenRequirements.gitea(scope: config?.gitea?.scope ?? "", instance: config?.gitea?.instance)
        }
        return TokenRequirements.github(scope: config?.repo ?? "")
    }

    /// Resolves `--account NAME` to its forge: "github"/"gitea" are the legacy
    /// accounts, anything else must be an `accounts:` entry in the config.
    static func resolveAccount(_ name: String, config: KinhinConfig?) -> AccountConfig? {
        config?.allAccounts.first { $0.name == name }
            ?? ForgeID(rawValue: name).map { AccountConfig(name: name, forge: $0, scope: "") }
    }

    /// `auth add NAME --github|--gitea --scope S [--instance URL] [--token T]`.
    private static func add(_ args: [String], environment: AuthEnvironment) throws {
        guard let name = args.dropFirst(2).first, !name.hasPrefix("--") else {
            try environment.fail(
                "usage: kinhin auth add NAME --github|--gitea --scope SCOPE [--instance URL] [--token T]")
        }
        let forge: ForgeID
        switch (args.contains("--github"), args.contains("--gitea")) {
        case (true, false): forge = .github
        case (false, true): forge = .gitea
        default: try environment.fail("choose exactly one of --github or --gitea")
        }
        guard let scope = flag("--scope", in: args) else {
            try environment.fail("--scope is required (an org name, or owner/name for one repository)")
        }
        let account = AccountConfig(name: name, forge: forge, scope: scope, instance: flag("--instance", in: args))
        do {
            try AccountsConfigEditor.add(account, to: environment.configURL)
        } catch {
            try environment.fail(error.localizedDescription)
        }
        print("account '\(name)' added to config (\(forge.rawValue): \(scope))")
        if let token = flag("--token", in: args) {
            try environment.saveAccount(token, forge, name)
            environment.notifyDaemonAccount(name, token)
            print("token stored in Keychain")
        } else {
            print("next: kinhin auth set --account \(name)")
        }
    }

    /// `auth list`: every account, its scope and whether a token is stored.
    private static func list(environment: AuthEnvironment) {
        let config: KinhinConfig? =
            if let fixture = environment.jsonConfig { fixture } else { AuthEnvironment.loadConfigTolerant() }
        let accounts = config?.allAccounts ?? []
        guard !accounts.isEmpty else {
            print("no accounts configured")
            return
        }
        for account in accounts {
            let token =
                account.name == account.forge.rawValue
                ? environment.load(account.forge) : environment.loadAccount(account.forge, account.name)
            let where_ = account.instance.map { "\(account.scope) @ \($0)" } ?? account.scope
            print(
                "\(account.name)\t\(account.forge.rawValue)\t\(where_)\t\(token == nil ? "no token" : "token stored")")
        }
    }

    /// `auth remove NAME`: drops the account from the config and its token.
    private static func remove(_ args: [String], environment: AuthEnvironment) throws {
        guard let name = args.dropFirst(2).first, !name.hasPrefix("--") else {
            try environment.fail("usage: kinhin auth remove NAME")
        }
        let config: KinhinConfig? =
            if let fixture = environment.jsonConfig { fixture } else { AuthEnvironment.loadConfigTolerant() }
        guard let account = config?.accounts.first(where: { $0.name == name }) else {
            try environment.fail(
                "no account '\(name)' in the accounts: list (the top-level repo:/gitea: sections are edited in config.yaml)"
            )
        }
        do {
            try AccountsConfigEditor.remove(name: name, at: environment.configURL)
        } catch {
            try environment.fail(error.localizedDescription)
        }
        environment.deleteAccount(account.forge, name)
        print("account '\(name)' removed (config entry and Keychain token)")
    }

    /// `environment` is injectable so tests can drive every flow with
    /// recording doubles — no real Keychain, stdin, or network.
    static func run(_ args: [String], environment: AuthEnvironment = .live) async throws {
        let sub = args.dropFirst().first ?? "set"
        switch sub {
        case "add": return try add(args, environment: environment)
        case "list": return list(environment: environment)
        case "remove": return try remove(args, environment: environment)
        default: break
        }
        // Platform selection: --gitea targets the Gitea token; default is GitHub.
        // --account NAME targets a named account (an accounts: entry).
        var giteaMode = args.contains("--gitea")
        var forge: ForgeID = giteaMode ? .gitea : .github
        var namedAccount: AccountConfig?
        if let accountName = flag("--account", in: args) {
            let config: KinhinConfig? =
                if let fixture = environment.jsonConfig { fixture } else { AuthEnvironment.loadConfigTolerant() }
            guard let resolved = resolveAccount(accountName, config: config) else {
                try environment.fail(
                    "no account '\(accountName)' in config — add it first: kinhin auth add \(accountName) --github|--gitea --scope SCOPE"
                )
            }
            forge = resolved.forge
            giteaMode = forge == .gitea
            // The legacy names keep their original Keychain items and RPCs.
            if resolved.name != resolved.forge.rawValue { namedAccount = resolved }
        }
        let forgeName =
            namedAccount.map { "\($0.forge == .gitea ? "Gitea access token" : "GitHub PAT") for account '\($0.name)'" }
            ?? (giteaMode ? "Gitea access token" : "GitHub PAT")
        let load: (ForgeID) -> String? = { f in
            namedAccount.map { environment.loadAccount($0.forge, $0.name) } ?? environment.load(f)
        }
        switch sub {
        case "set":
            let token: String
            if let explicit = flag("--token", in: args) {
                token = explicit
            } else {
                // Say what the token needs before asking for it, so it is
                // created with the right permissions the first time.
                let config: KinhinConfig? =
                    if let fixture = environment.jsonConfig { fixture } else { AuthEnvironment.loadConfigTolerant() }
                print(Self.requirements(for: forge, config: config).plainText)
                print("")
                print("Paste your \(forgeName) (input hidden), then press Enter:")
                let entered = environment.readToken()?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let entered, !entered.isEmpty else {
                    try environment.fail("no token entered")
                }
                token = entered
            }
            if let namedAccount {
                try environment.saveAccount(token, namedAccount.forge, namedAccount.name)
                environment.notifyDaemonAccount(namedAccount.name, token)
            } else {
                try environment.save(token, forge)
                environment.notifyDaemon(token, forge)
            }
            print("\(forgeName) stored in Keychain")
        case "status":
            // Machine output first: the whole point is a fast, deterministic,
            // scriptable snapshot — never a network probe, never an early
            // exit before the JSON lands.
            if args.contains("--json") {
                let (report, _) = try Self.emitStatusJSON(environment: environment)
                if !report.allGood {
                    try environment.exit(1)
                }
                return
            }
            guard let token = load(forge) else {
                print(giteaMode ? "no Gitea token stored" : "no token stored")
                try environment.exit(1)
            }
            let cfg = environment.loadConfig()
            if let namedAccount {
                print("token stored (starts with \(token.prefix(4))…), checking \(namedAccount.scope)…")
                do {
                    if let instance = namedAccount.instance {
                        try await environment.checkGitea(
                            GiteaCredentials(token: token, scope: namedAccount.scope, instance: instance))
                    } else {
                        try await environment.checkGitHub(GitHubCredentials(token: token, scope: namedAccount.scope))
                    }
                    print("token works against \(namedAccount.scope)")
                } catch {
                    print("token check failed: \(error.localizedDescription)")
                    try environment.exit(1)
                }
            } else if giteaMode {
                guard let gitea = cfg.gitea else {
                    try environment.fail("no gitea section in config — add it before checking the Gitea token")
                }
                print("Gitea token stored (starts with \(token.prefix(4))…), checking \(gitea.instance)…")
                do {
                    try await environment.checkGitea(
                        GiteaCredentials(token: token, scope: gitea.scope, instance: gitea.instance))
                    print("token works against \(gitea.scope) @ \(gitea.instance)")
                } catch {
                    print("token check failed: \(error.localizedDescription)")
                    print("")
                    print(Self.requirements(for: .gitea, config: cfg).plainText)
                    try environment.exit(1)
                }
            } else {
                print("token stored (starts with \(token.prefix(4))…), checking…")
                do {
                    try await environment.checkGitHub(GitHubCredentials(token: token, scope: cfg.repo))
                    print("token works against \(cfg.repo)")
                } catch {
                    print("token check failed: \(error.localizedDescription)")
                    print("")
                    print(Self.requirements(for: .github, config: cfg).plainText)
                    try environment.exit(1)
                }
            }
        case "clear":
            if let namedAccount {
                environment.deleteAccount(namedAccount.forge, namedAccount.name)
            } else {
                environment.delete(forge)
            }
            print("\(forgeName) removed")
        default:
            try environment.fail("unknown auth subcommand '\(sub)' (use set|status|clear|list|add|remove)")
        }
    }
}
