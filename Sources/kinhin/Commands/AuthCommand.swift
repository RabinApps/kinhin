import Foundation
import KinhinKit

enum AuthCommand {
    /// The machine-readable status report without printing — shared with the
    /// MCP `auth_status` tool. Static — no network probes, tolerant of a
    /// missing config file: the report's job is to report what's missing, not
    /// fail on it. Defaults read the live Keychain; the CLI path passes its
    /// injected environment instead.
    static func statusReport(
        jsonConfig: KinhinConfig?? = nil,
        load: @Sendable (ForgeID) throws -> String? = AuthEnvironment.live.load,
        loadAccount: @Sendable (ForgeID, String) throws -> String? = AuthEnvironment.live.loadAccount
    ) -> AuthStatusReport {
        AuthStatusReporter.report(
            config: jsonConfig ?? AuthEnvironment.loadConfigTolerant(),
            load: load,
            loadAccount: loadAccount
        )
    }

    /// Builds, prints, and returns the machine-readable status document.
    /// Static — no network probes, tolerant of a missing config file.
    static func emitStatusJSON(environment: AuthEnvironment) throws -> (report: AuthStatusReport, data: Data) {
        let report = statusReport(
            jsonConfig: environment.jsonConfig,
            load: environment.load,
            loadAccount: environment.loadAccount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        print(String(decoding: data, as: UTF8.self))
        return (report, data)
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
