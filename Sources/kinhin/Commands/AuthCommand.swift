import Foundation
import KinhinKit

/// Injectable dependencies for the auth command. `.live` talks to the real
/// Keychain, stdin, forge APIs, and daemon socket; tests substitute recording
/// doubles so token flows never touch the login Keychain or the network.
///
/// The `fail`/`exit` hooks are throwing `Never`-returning functions: live
/// behavior terminates the process, tests throw a catchable error and assert
/// on the code/message instead.
struct AuthEnvironment: Sendable {
    var save: @Sendable (String, ForgeID) throws -> Void
    /// Returns the stored token for the forge, or nil when none is stored.
    var load: @Sendable (ForgeID) throws -> String?
    var delete: @Sendable (ForgeID) -> Void
    /// Interactive read for `auth set` without --token (raw stdin line).
    var readToken: @Sendable () -> String?
    /// `auth status` probe — throws when the forge rejects the token.
    var checkGitHub: @Sendable (GitHubCredentials) async throws -> Void
    var checkGitea: @Sendable (GiteaCredentials) async throws -> Void
    var checkGitLab: @Sendable (GitLabCredentials) async throws -> Void = { credentials in
        let report = await TokenHealthCheck.gitlab(
            token: credentials.token, scope: credentials.scope, instance: credentials.instance)
        guard report.ok else { throw CLIError(report.message) }
    }
    var loadConfig: @Sendable () -> KinhinConfig
    /// Best-effort live-swap notification to a running daemon.
    var notifyDaemon: @Sendable (String, ForgeID) -> Void
    /// stderr `kinhin: <message>` + exit 1.
    var fail: @Sendable (String) throws -> Never
    /// Bare exit (stdout already carries the user-facing line).
    var exit: @Sendable (Int) throws -> Never
    /// Named-account token access (`--account NAME`, `auth add/remove`).
    var saveAccount: @Sendable (String, ForgeID, String) throws -> Void = {
        try KeychainTokenStore.save($0, forge: $1, name: $2)
    }
    var loadAccount: @Sendable (ForgeID, String) throws -> String? = {
        try KeychainTokenStore.load(forge: $0, name: $1)
    }
    var deleteAccount: @Sendable (ForgeID, String) -> Void = { KeychainTokenStore.delete(forge: $0, name: $1) }
    /// Best-effort live-swap notification for a named account: (account, token).
    var notifyDaemonAccount: @Sendable (String, String) -> Void = { account, token in
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
        load: { try KeychainTokenStore.load(forge: $0) },
        delete: { KeychainTokenStore.delete(forge: $0) },
        readToken: { String(data: FileHandle.standardInput.availableData, encoding: .utf8) },
        checkGitHub: { credentials in _ = try await GitHubClient(credentials: credentials).listRunners() },
        checkGitea: { credentials in _ = try await GiteaClient(credentials: credentials).fetchRegistrationToken() },
        loadConfig: { loadConfigOrExit() },
        notifyDaemon: { token, forge in
            switch forge {
            case .github: notifyDaemonTokenReplaced(token)
            case .gitea: notifyDaemonGiteaTokenReplaced(token)
            case .forgejo: notifyDaemonForgejoTokenReplaced(token)
            // GitLab has no legacy section: its tokens always go through accounts.
            case .gitlab: notifyDaemonAccountTokenReplaced(account: ForgeID.gitlab.rawValue, token: token)
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
        switch forge {
        case .gitea:
            return TokenRequirements.gitea(scope: config?.gitea?.scope ?? "", instance: config?.gitea?.instance)
        case .forgejo:
            return TokenRequirements.gitea(scope: config?.forgejo?.scope ?? "", instance: config?.forgejo?.instance)
        case .github:
            return TokenRequirements.github(scope: config?.repo ?? "")
        case .gitlab:
            let account = config?.accounts.first { $0.forge == .gitlab }
            return TokenRequirements.gitlab(scope: account?.scope ?? "", instance: account?.instance)
        }
    }

    /// Resolves `--account NAME` to its forge: "github"/"gitea"/"forgejo" are
    /// the legacy accounts, anything else must be an `accounts:` entry in the
    /// config.
    static func resolveAccount(_ name: String, config: KinhinConfig?) -> AccountConfig? {
        config?.allAccounts.first { $0.name == name }
            ?? ForgeID(rawValue: name).flatMap { forge in
                AccountConfig.reservedNames.contains(name) ? AccountConfig(name: name, forge: forge, scope: "") : nil
            }
    }

    /// The forge chosen by `--github`/`--gitea`/`--forgejo`/`--gitlab`; nil
    /// when none or several are given.
    static func forgeFlag(in args: [String]) -> ForgeID? {
        let chosen = ForgeID.allCases.filter { args.contains("--\($0.rawValue)") }
        return chosen.count == 1 ? chosen.first : nil
    }

    /// `auth add NAME --github|--gitea|--forgejo|--gitlab --scope S [--instance URL] [--token T]`.
    private static func add(_ args: [String], environment: AuthEnvironment) throws {
        guard let name = args.dropFirst(2).first, !name.hasPrefix("--") else {
            try environment.fail(
                "usage: kinhin auth add NAME --github|--gitea|--forgejo|--gitlab --scope SCOPE [--instance URL] [--token T]"
            )
        }
        guard let forge = forgeFlag(in: args) else {
            try environment.fail("choose exactly one of --github, --gitea, --forgejo or --gitlab")
        }
        guard let scope = flag("--scope", in: args) else {
            try environment.fail(
                forge == .gitlab
                    ? "--scope is required (a GitLab project or group path, e.g. group/project)"
                    : "--scope is required (an org name, or owner/name for one repository)")
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
            let state: String
            do {
                let token =
                    try account.name == account.forge.rawValue
                    ? environment.load(account.forge) : environment.loadAccount(account.forge, account.name)
                state = token == nil ? "no token" : "token stored"
            } catch {
                // Report it on this row (and keep listing the rest) rather than claim "no token".
                state = "keychain error: \(error.localizedDescription)"
            }
            let where_ = account.instance.map { "\(account.scope) @ \($0)" } ?? account.scope
            print("\(account.name)\t\(account.forge.rawValue)\t\(where_)\t\(state)")
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
        // Platform selection: --gitea/--forgejo target those tokens; default
        // is GitHub. --account NAME targets a named account (an accounts:
        // entry).
        var giteaMode = args.contains("--gitea") || args.contains("--forgejo")
        var forge: ForgeID = args.contains("--forgejo") ? .forgejo : (giteaMode ? .gitea : .github)
        var namedAccount: AccountConfig?
        // GitLab has no top-level section: --gitlab means the (first) GitLab account.
        var accountFlag = flag("--account", in: args)
        if accountFlag == nil, args.contains("--gitlab") {
            let config: KinhinConfig? =
                if let fixture = environment.jsonConfig { fixture } else { AuthEnvironment.loadConfigTolerant() }
            guard let gitlab = config?.accounts.first(where: { $0.forge == .gitlab }) else {
                try environment.fail(
                    "no GitLab account in config — add one first: kinhin auth add NAME --gitlab --scope group/project")
            }
            accountFlag = gitlab.name
        }
        if let accountName = accountFlag {
            let config: KinhinConfig? =
                if let fixture = environment.jsonConfig { fixture } else { AuthEnvironment.loadConfigTolerant() }
            guard let resolved = resolveAccount(accountName, config: config) else {
                try environment.fail(
                    "no account '\(accountName)' in config — add it first: kinhin auth add \(accountName) --github|--gitea|--forgejo|--gitlab --scope SCOPE"
                )
            }
            forge = resolved.forge
            giteaMode = forge != .github
            // The legacy names keep their original Keychain items and RPCs;
            // GitLab has none, so every GitLab account is a named one.
            if resolved.name != resolved.forge.rawValue || resolved.forge == .gitlab { namedAccount = resolved }
        }
        let forgeLabel = { (forge: ForgeID) -> String in
            switch forge {
            case .github: return "GitHub PAT"
            case .gitea: return "Gitea access token"
            case .forgejo: return "Forgejo access token"
            case .gitlab: return "GitLab access token"
            }
        }
        let forgeName =
            namedAccount.map { "\(forgeLabel($0.forge)) for account '\($0.name)'" }
            ?? forgeLabel(forge)
        let load: (ForgeID) throws -> String? = { f in
            try namedAccount.map { try environment.loadAccount($0.forge, $0.name) } ?? environment.load(f)
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
            guard let token = try load(forge) else {
                print(namedAccount != nil || giteaMode ? "no \(forgeName) stored" : "no token stored")
                try environment.exit(1)
            }
            let cfg = environment.loadConfig()
            if let namedAccount {
                print("token stored (starts with \(token.prefix(4))…), checking \(namedAccount.scope)…")
                do {
                    switch namedAccount.forge {
                    case .github:
                        try await environment.checkGitHub(GitHubCredentials(token: token, scope: namedAccount.scope))
                    case .gitea, .forgejo:
                        try await environment.checkGitea(
                            GiteaCredentials(
                                token: token, scope: namedAccount.scope, instance: namedAccount.instance ?? ""))
                    case .gitlab:
                        try await environment.checkGitLab(
                            GitLabCredentials(token: token, scope: namedAccount.scope, instance: namedAccount.instance))
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
