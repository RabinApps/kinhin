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
    var checkBuildkite: @Sendable (BuildkiteCredentials) async throws -> Void = { credentials in
        let report = await TokenHealthCheck.buildkite(token: credentials.token, scope: credentials.scope)
        guard report.ok else { throw CLIError(report.message) }
    }
    var checkAzureDevOps: @Sendable (AzureDevOpsCredentials) async throws -> Void = { credentials in
        let report = await TokenHealthCheck.azureDevOps(
            token: credentials.token, scope: credentials.scope, instance: credentials.instance)
        guard report.ok else { throw CLIError(report.message) }
    }
    var checkBitbucket: @Sendable (BitbucketCredentials) async throws -> Void = { credentials in
        let report = await TokenHealthCheck.bitbucket(token: credentials.token, scope: credentials.scope)
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
        notifyDaemonTokenReplaced(.account(account), token: token)
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

    /// The config account lookups read: the test fixture when set, else the
    /// live file (nil when missing or unreadable).
    var lookupConfig: KinhinConfig? {
        if let fixture = jsonConfig { fixture } else { Self.loadConfigTolerant() }
    }

    static let live = AuthEnvironment(
        save: { try KeychainTokenStore.save($0, forge: $1) },
        load: { try KeychainTokenStore.load(forge: $0) },
        delete: { KeychainTokenStore.delete(forge: $0) },
        readToken: { readSecretLine() },
        checkGitHub: { credentials in _ = try await GitHubClient(credentials: credentials).listRunners() },
        checkGitea: { credentials in _ = try await GiteaClient(credentials: credentials).fetchRegistrationToken() },
        loadConfig: { loadConfigOrExit() },
        notifyDaemon: { token, forge in notifyDaemonTokenReplaced(.forge(forge), token: token) },
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
        case .buildkite:
            return TokenRequirements.buildkite(scope: config?.accounts.first { $0.forge == .buildkite }?.scope ?? "")
        case .azuredevops:
            let account = config?.accounts.first { $0.forge == .azuredevops }
            return TokenRequirements.azureDevOps(scope: account?.scope ?? "", instance: account?.instance)
        case .bitbucket:
            return TokenRequirements.bitbucket(scope: config?.accounts.first { $0.forge == .bitbucket }?.scope ?? "")
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

    /// The forge chosen by `--github`/`--gitlab`/`--gitea`/… ; nil when none
    /// or several are given.
    static func forgeFlag(in args: [String]) -> ForgeID? {
        let chosen = ForgeID.allCases.filter { args.contains("--\($0.rawValue)") }
        return chosen.count == 1 ? chosen.first : nil
    }

    /// Every forge flag, for usage lines: `--github|--gitlab|…`.
    static var forgeFlagList: String {
        ForgeID.allCases.map { "--\($0.rawValue)" }.joined(separator: "|")
    }

    /// `auth add NAME --github|--gitlab|… --scope S [--instance URL] [--token T]`.
    private static func add(_ args: [String], environment: AuthEnvironment) throws {
        guard let name = args.dropFirst(2).first, !name.hasPrefix("--") else {
            try environment.fail(
                "usage: kinhin auth add NAME \(forgeFlagList) --scope SCOPE [--instance URL] [--token T]"
            )
        }
        guard let forge = forgeFlag(in: args) else {
            try environment.fail("choose exactly one of \(forgeFlagList.replacingOccurrences(of: "|", with: ", "))")
        }
        guard let scope = flag("--scope", in: args) else {
            let expected: String
            switch forge {
            case .gitlab: expected = "a GitLab project or group path, e.g. group/project"
            case .buildkite: expected = "org-slug/cluster, the cluster's name or id"
            case .azuredevops: expected = "the agent pool's name, with --instance https://dev.azure.com/ORG"
            case .bitbucket: expected = "a workspace slug, or workspace/repo-slug for one repository"
            case .github, .gitea, .forgejo: expected = "an org name, or owner/name for one repository"
            }
            try environment.fail("--scope is required (\(expected))")
        }
        let account = AccountConfig(name: name, forge: forge, scope: scope, instance: flag("--instance", in: args))
        do {
            try AccountsConfigEditor.add(account, to: environment.configURL)
        } catch {
            try environment.fail(error.localizedDescription)
        }
        print("account '\(name)' added to config (\(forge.rawValue): \(scope))")
        if let token = flag("--token", in: args) {
            warnTokenOnCommandLine()
            try environment.saveAccount(token, forge, name)
            environment.notifyDaemonAccount(name, token)
            print("token stored in Keychain")
        } else {
            print("next: kinhin auth set --account \(name)")
        }
    }

    /// `auth list`: every account, its scope and whether a token is stored.
    private static func list(environment: AuthEnvironment) {
        let config = environment.lookupConfig
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
        let config = environment.lookupConfig
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
        case "set", "status", "clear": break
        default: try environment.fail("unknown auth subcommand '\(sub)' (use set|status|clear|list|add|remove)")
        }
        let target = try resolveTarget(args, environment: environment)
        switch sub {
        case "set": try setToken(args, target: target, environment: environment)
        case "status": try await status(args, target: target, environment: environment)
        default: clear(target: target, environment: environment)
        }
    }

    // MARK: - set / status / clear

    /// The token `set`, `status` and `clear` act on: a forge's primary token
    /// (`--gitea`, `--forgejo`, default GitHub) or a named account
    /// (`--account NAME`; `--gitlab` means the first GitLab account).
    struct Target {
        var forge: ForgeID
        /// Set for a named account with its own Keychain item.
        var named: AccountConfig?

        var label: String {
            let kind: String
            switch forge {
            case .github: kind = "GitHub PAT"
            case .gitea: kind = "Gitea access token"
            case .forgejo: kind = "Forgejo access token"
            case .gitlab: kind = "GitLab access token"
            case .buildkite: kind = "Buildkite API access token"
            case .azuredevops: kind = "Azure DevOps personal access token"
            case .bitbucket: kind = "Bitbucket access token"
            }
            return named.map { "\(kind) for account '\($0.name)'" } ?? kind
        }

        func load(_ environment: AuthEnvironment) throws -> String? {
            try named.map { try environment.loadAccount($0.forge, $0.name) } ?? environment.load(forge)
        }
    }

    static func resolveTarget(_ args: [String], environment: AuthEnvironment) throws -> Target {
        var target = Target(
            forge: args.contains("--forgejo") ? .forgejo : (args.contains("--gitea") ? .gitea : .github))
        var accountFlag = flag("--account", in: args)
        // Forges without a primary account (GitLab, Buildkite): the flag
        // means the forge's first account.
        let accountOnly = ForgeID.allCases.filter { !AccountConfig.reservedNames.contains($0.rawValue) }
        if accountFlag == nil, let forge = accountOnly.first(where: { args.contains("--\($0.rawValue)") }) {
            guard let first = environment.lookupConfig?.accounts.first(where: { $0.forge == forge }) else {
                try environment.fail(
                    "no \(forge.displayName) account in config — add one first: kinhin auth add NAME --\(forge.rawValue) --scope SCOPE"
                )
            }
            accountFlag = first.name
        }
        if let accountName = accountFlag {
            guard let resolved = resolveAccount(accountName, config: environment.lookupConfig) else {
                try environment.fail(
                    "no account '\(accountName)' in config — add it first: kinhin auth add \(accountName) \(forgeFlagList) --scope SCOPE"
                )
            }
            target.forge = resolved.forge
            // The conventional names keep their original Keychain items and
            // RPCs; the other forges have none, so all their accounts are
            // named ones.
            if resolved.name != resolved.forge.rawValue
                || !AccountConfig.reservedNames.contains(resolved.forge.rawValue)
            {
                target.named = resolved
            }
        }
        return target
    }

    /// A token passed as an argument lands in shell history and is visible in
    /// the process list; say so, and point at the hidden prompt / piped stdin.
    private static func warnTokenOnCommandLine() {
        warn(
            "--token puts the token in your shell history and process list; run `kinhin auth set` and paste it at the prompt (or pipe it on stdin) instead"
        )
    }

    /// `auth set`: store the token (from --token or stdin) and hand it to a
    /// running daemon.
    private static func setToken(_ args: [String], target: Target, environment: AuthEnvironment) throws {
        let token: String
        if let explicit = flag("--token", in: args) {
            warnTokenOnCommandLine()
            token = explicit
        } else {
            // Say what the token needs before asking for it, so it is
            // created with the right permissions the first time.
            print(Self.requirements(for: target.forge, config: environment.lookupConfig).plainText)
            print("")
            print("Paste your \(target.label) (input hidden), then press Enter:")
            let entered = environment.readToken()?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let entered, !entered.isEmpty else {
                try environment.fail("no token entered")
            }
            token = entered
        }
        if let named = target.named {
            try environment.saveAccount(token, named.forge, named.name)
            environment.notifyDaemonAccount(named.name, token)
        } else {
            try environment.save(token, target.forge)
            environment.notifyDaemon(token, target.forge)
        }
        print("\(target.label) stored in Keychain")
    }

    /// `auth status`: check the stored token against its forge (or, with
    /// --json, the static report with no network probe).
    private static func status(_ args: [String], target: Target, environment: AuthEnvironment) async throws {
        // Machine output first: a fast, deterministic, scriptable snapshot —
        // never a network probe, never an early exit before the JSON lands.
        if args.contains("--json") {
            let (report, _) = try Self.emitStatusJSON(environment: environment)
            if !report.allGood { try environment.exit(1) }
            return
        }
        guard let token = try target.load(environment) else {
            print(target.named != nil || target.forge != .github ? "no \(target.label) stored" : "no token stored")
            try environment.exit(1)
        }
        let cfg = environment.loadConfig()
        // What to check against: the named account, the forge's primary
        // account, or (GitHub) the configured repo scope.
        let account: AccountConfig
        if let named = target.named {
            account = named
        } else if target.forge == .github {
            // The primary account carries the enterprise instance, so a GHES
            // check hits that host instead of github.com.
            account = cfg.primaryGitHub ?? AccountConfig(name: "github", forge: .github, scope: cfg.repo)
        } else {
            guard let primary = target.forge == .forgejo ? cfg.forgejo : cfg.gitea else {
                try environment.fail(
                    "no \(target.forge.rawValue) account in config — add one before checking the \(target.forge == .forgejo ? "Forgejo" : "Gitea") token"
                )
            }
            account = AccountConfig(
                name: target.forge.rawValue, forge: target.forge, scope: primary.scope, instance: primary.instance)
        }
        // A forge's primary Gitea-family token names the forge and its
        // server; everything else checks against the scope.
        let selfHostedPrimary = target.named == nil && target.forge != .github
        let noun = selfHostedPrimary ? "\(target.forge == .forgejo ? "Forgejo" : "Gitea") token" : "token"
        let checking = selfHostedPrimary ? account.instance ?? "" : account.scope
        let against = selfHostedPrimary ? "\(account.scope) @ \(checking)" : account.scope
        print("\(noun) stored (starts with \(token.prefix(4))…), checking \(checking)…")
        do {
            switch account.forge {
            case .github:
                try await environment.checkGitHub(
                    GitHubCredentials(
                        token: token, scope: account.scope, instance: account.instance,
                        allowInsecureHTTP: account.allowInsecureHTTP ?? false))
            case .gitea, .forgejo:
                try await environment.checkGitea(
                    GiteaCredentials(
                        token: token, scope: account.scope, instance: account.instance ?? "",
                        allowInsecureHTTP: account.allowInsecureHTTP ?? false))
            case .gitlab:
                try await environment.checkGitLab(
                    GitLabCredentials(
                        token: token, scope: account.scope, instance: account.instance,
                        allowInsecureHTTP: account.allowInsecureHTTP ?? false))
            case .buildkite:
                try await environment.checkBuildkite(BuildkiteCredentials(token: token, scope: account.scope))
            case .azuredevops:
                try await environment.checkAzureDevOps(
                    AzureDevOpsCredentials(
                        token: token, scope: account.scope, instance: account.instance ?? "",
                        allowInsecureHTTP: account.allowInsecureHTTP ?? false))
            case .bitbucket:
                try await environment.checkBitbucket(BitbucketCredentials(token: token, scope: account.scope))
            }
            print("token works against \(against)")
        } catch {
            print("token check failed: \(error.localizedDescription)")
            if target.named == nil {
                print("")
                print(Self.requirements(for: target.forge, config: cfg).plainText)
            }
            try environment.exit(1)
        }
    }

    /// `auth clear`: delete the stored token.
    private static func clear(target: Target, environment: AuthEnvironment) {
        if let named = target.named {
            environment.deleteAccount(named.forge, named.name)
        } else {
            environment.delete(target.forge)
        }
        print("\(target.label) removed")
    }
}

/// Reads one line from stdin. On a terminal the echo is switched off while
/// typing (the prompt promises hidden input) and restored afterwards; piped
/// input is read as-is.
func readSecretLine() -> String? {
    let fd = STDIN_FILENO
    var original = termios()
    let isTerminal = isatty(fd) == 1 && tcgetattr(fd, &original) == 0
    if isTerminal {
        var silent = original
        silent.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(fd, TCSANOW, &silent)
    }
    defer {
        if isTerminal {
            tcsetattr(fd, TCSANOW, &original)
            print("")  // the Enter keypress was not echoed
        }
    }
    return readLine(strippingNewline: true)
}
