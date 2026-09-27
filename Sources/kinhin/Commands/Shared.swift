import Foundation
import KinhinKit

@discardableResult
func noteAutoCreatedConfigIfMissing() -> Bool {
    if ConfigLoader.createIfMissing() {
        FileHandle.standardError.write(
            Data(
                "note: created starter config at \(Paths.config.path) — set your repo, then run `kinhin auth set`\n"
                    .utf8))
        return true
    }
    return false
}

/// After `auth set` saves a fresh PAT, tell a running daemon so the swap is
/// live immediately (otherwise it would keep the old token until restart).
/// Best-effort: no daemon is not an error.
func notifyDaemonTokenReplaced(_ pat: String) {
    guard RPCClient.isDaemonAlive() else { return }
    do {
        try RPCClient().replaceToken(pat: pat)
        print("running daemon notified — new token is live")
    } catch {
        warn("could not notify running daemon (\(error.localizedDescription)); restart it to pick up the new token")
    }
}

/// Same best-effort notification for the Gitea token.
func notifyDaemonGiteaTokenReplaced(_ token: String) {
    guard RPCClient.isDaemonAlive() else { return }
    do {
        try RPCClient().replaceGiteaToken(token)
        print("running daemon notified — new Gitea token is live")
    } catch {
        warn("could not notify running daemon (\(error.localizedDescription)); restart it to pick up the new token")
    }
}

/// Same best-effort notification for the Forgejo token.
func notifyDaemonForgejoTokenReplaced(_ token: String) {
    guard RPCClient.isDaemonAlive() else { return }
    do {
        try RPCClient().replaceForgejoToken(token)
        print("running daemon notified — new Forgejo token is live")
    } catch {
        warn("could not notify running daemon (\(error.localizedDescription)); restart it to pick up the new token")
    }
}

/// Same best-effort notification for a named account's token.
func notifyDaemonAccountTokenReplaced(account: String, token: String) {
    guard RPCClient.isDaemonAlive() else { return }
    do {
        try RPCClient().replaceAccountToken(account: account, token: token)
        print("running daemon notified — new token for '\(account)' is live")
    } catch {
        warn("could not notify running daemon (\(error.localizedDescription)); restart it to pick up the new token")
    }
}

/// Process exit codes. Scripts can branch on them: 1 for anything
/// unclassified, 2 for a bad command line, then one per problem area.
enum CLIExit: Int32 {
    case general = 1
    case usage = 2
    case config = 3
    case runtime = 4
    case auth = 5

    /// The exit code for an error thrown anywhere in the engine or CLI.
    init(_ error: Error) {
        if let cliError = error as? CLIError {
            self = cliError.exit
            return
        }
        switch ErrorCategory(error) {
        case .config: self = .config
        case .auth: self = .auth
        case .runtime: self = .runtime
        case .other: self = .general
        }
    }
}

/// A failure the CLI itself detected (bad arguments, missing prerequisite),
/// carrying the exit code it should end the process with.
struct CLIError: LocalizedError {
    let message: String
    let exit: CLIExit

    init(_ message: String, exit: CLIExit = .general) {
        self.message = message
        self.exit = exit
    }

    var errorDescription: String? { message }
}

/// Writes to stderr, keeping stdout clean for machine-readable output.
func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// A non-fatal problem. Goes to stderr so `--json` output stays parseable.
func warn(_ message: String) {
    printError("warning: \(message)")
}

func fail(_ message: String, exit code: CLIExit = .general) -> Never {
    printError("kinhin: \(message)")
    exit(code.rawValue)
}

/// Ends the process for a thrown error, with an exit code matching its kind.
func fail(_ error: Error) -> Never {
    fail(error.localizedDescription, exit: CLIExit(error))
}

/// The full help screen, one call site for the printer and tests alike.
func helpText() -> String {
    """
    kinhin — autoscaling CI runners on your Mac (GitHub Actions & Gitea Actions)
    macOS jobs run on Tart VMs; Linux jobs on apple/container microVMs or Docker

    USAGE:
        kinhin <command> [options]

    SETUP:
        config init                 Write a starter config file
        auth [set]                  Store (or replace) your GitHub PAT in the Keychain (or: auth set --token)
        auth set --gitea            Store (or replace) your Gitea access token (auth set --gitea --token X)
        auth set --account NAME     Store the token for a named account (--token X to skip the prompt)
        auth add NAME --github|--gitea --scope S [--instance URL] [--token X]
                                    Add another GitHub or Gitea account to the config
        auth list                   List every account and whether its token is stored
        auth remove NAME            Remove an account from the config and delete its token
        auth status [--json]        Show whether a token is stored and valid (--json: all forges, machine output, exit 1 until ready)
        auth clear                  Remove the stored token
        doctor [--json]             Check prerequisites and print the computed capacity (--json: merged machine-readable diagnostics document)
        setup-status [--json]       First-run checklist (pass --json for machine output)
        setup repair host-agent     Install the GitHub + Gitea runner agents for host runs (unisolated, on this Mac)
        setup repair docker [--method desktop|orbstack|colima]
                                    Install Docker (default: the first method this Mac supports)
        setup repair container      Install Apple container and its system service (Apple silicon, macOS 26+)
        setup repair tart           Install tart for macOS VMs
        runtimes [--json]           Pools, capacity, budget, health, and routes (--no-health skips probes)
        runtimes route add <pat> <rt>   Route a repo (owner/repo) or workflow (owner/repo@Name) to tart|appleContainer|docker|host
                                    (host runs unisolated on this Mac and needs --consent)
        runtimes route remove <pat>     Delete that route; a running daemon reloads routing live
        image prepare [--provision-script <file>]
                                    Build the runner base image (slow, once); the script
                                    bakes your toolchains in after the agents install.
                                    Also bakes `toolchains:` config entries and uses the
                                    shared host download cache (auto-pruned)
        image prepare --toolchain <spec> [--stack <name>]
                                    Override the config's toolchains for this prepare
        image prepare --container   Build the Linux container image (apple container);
                                    bakes `toolchains:` too — macOS-only entries are
                                    skipped (use --linux-toolchain/--linux-stack to override)
        image prepare --docker      Build the Linux container image (Docker Desktop /
                                    OrbStack / colima); bakes `toolchains:` the same way.
                                    --platform linux/amd64 bakes an x86_64 image that runs
                                    under emulation (slower; see docs)
        toolchains                  Managed-toolchain catalog, selections, and cache state
        toolchains prune [--dry-run]   Expire stale host-cache entries now
        toolchains helper [--linux]    Print the per-job `kinhin-toolchain` helper baked into images

    RUNNING:
        start                       Start the fleet in this terminal (Ctrl-C to stop)
        daemon                      Run the headless daemon in this terminal
        daemon install              Install and start a LaunchAgent daemon
        daemon uninstall            Stop and remove the LaunchAgent
        status                      Show fleet status (attach to daemon if running)
        pause | resume              Hold the fleet / let it scale again
        stop                        Stop the fleet (works on daemon or in-process)
        logs [-n N]                 Show recent log lines
        watch                       Live status view (refreshes every 2s)

    OTHER:
        version                     Print version
        help                        Show this help
    """
}

func printHelp(toStandardError: Bool = false) {
    if toStandardError {
        printError(helpText())
    } else {
        print(helpText())
    }
}

func loadConfigOrExit() -> KinhinConfig {
    do {
        let cfg = try ConfigLoader.load()
        return cfg
    } catch {
        fail(error)
    }
}

/// The token the engine is built with: the GitHub PAT, or an empty
/// placeholder for a Gitea-only config (whose own token is required instead).
func tokenOrExit(for cfg: KinhinConfig) -> String {
    let stored: String?
    do {
        stored = try ConfigLoader.engineToken(for: cfg)
    } catch {
        fail(error.localizedDescription, exit: .auth)
    }
    guard let token = stored else {
        fail(
            cfg.githubEnabled
                ? "no GitHub token stored. Run: kinhin auth set"
                : cfg.gitea != nil
                    ? "no Gitea token stored. Run: kinhin auth set --gitea"
                    : "no account has a token stored. See: kinhin auth list, then kinhin auth set --account NAME",
            exit: .auth)
    }
    return token
}

func engineFromConfig(_ cfg: KinhinConfig) throws -> FleetEngine {
    // The auto-created template parses cleanly but names a placeholder repo —
    // never boot a fleet (and start polling GitHub) against it.
    if !ConfigLoader.hasAnyForge(cfg) {
        fail(
            "config has no forge yet — set your repo (or a gitea: section) in \(Paths.config.path) first",
            exit: .config)
    }
    let tart = try cfg.makeTartControlling()
    let host = ResourceProbe().snapshot()
    let engine = FleetEngine(
        config: cfg,
        pat: tokenOrExit(for: cfg),
        tart: tart,
        store: FleetStore(),
        ssh: SSHExecutor(),
        host: host
    )
    engine.useLiveDiskProbe()
    return engine
}

func renderStatus(_ status: FleetStatus) -> String {
    var lines: [String] = []
    lines.append("engine:    \(status.running ? (status.paused ? "paused" : "running") : "stopped")")
    lines.append(
        "repo:      (see config)   queue: \(status.queueDepth)   desired: \(status.desired)   capacity cap: \(status.capacityCap)"
    )
    lines.append("job slots: \(status.jobCapacity) concurrent jobs (VM cap × runners_per_vm)")
    if let byRepo = status.queueByRepo, byRepo.count > 1 {
        let breakdown = byRepo.sorted { $0.value > $1.value }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
        lines.append("queue by repo: \(breakdown)")
    } else if let byRepo = status.queueByRepo, let only = byRepo.first, status.queueDepth > 0 {
        lines.append("queue by repo: \(only.key) ×\(only.value)")
    }
    if let byRepo = status.runningByRepo, status.activeCount > 0, !byRepo.isEmpty {
        let breakdown = byRepo.sorted { $0.value > $1.value }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
        lines.append("running by repo: \(breakdown)")
    }
    if let err = status.lastError {
        lines.append("last error: \(err)")
    }
    if status.records.isEmpty {
        lines.append("no VMs")
    } else {
        lines.append("VMs:")
        for record in status.records {
            var line = "  \(record.id)  \(record.phase.rawValue)"
            if let platform = record.platform, platform != "github" { line += " [\(platform)]" }
            if let ip = record.ip { line += "  ip=\(ip)" }
            line += "  up=\(Int(Date().timeIntervalSince(record.createdAt)))s"
            if let job = record.job { line += "  job=\(job)" }
            if let repos = record.repos, !repos.isEmpty { line += "  repos=\(repos.joined(separator: ","))" }
            if let err = record.error { line += "  error=\(err.prefix(120))" }
            lines.append(line)
        }
    }
    return lines.joined(separator: "\n")
}

// A tiny flag parser: --key value / --flag.
func flag(_ name: String, in args: [String]) -> String? {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

func hasFlag(_ name: String, in args: [String]) -> Bool {
    args.contains(name)
}

/// All values for a repeatable `--flag <value>` argument, in order.
func allFlags(_ name: String, in args: [String]) -> [String] {
    var values: [String] = []
    var index = args.startIndex
    while let found = args[index...].firstIndex(of: name) {
        let valueIndex = args.index(after: found)
        guard valueIndex < args.endIndex else { break }
        values.append(args[valueIndex])
        index = args.index(after: valueIndex)
    }
    return values
}

/// Config-file management (the `config init` command).
enum ConfigCommands {
    /// `configURL` is injectable so tests can exercise the write/exists/force
    /// matrix against a scratch directory.
    static func configInit(_ args: [String], configURL: URL = Paths.config) throws {
        let force = args.contains("--force")
        if FileManager.default.fileExists(atPath: configURL.path), !force {
            print("config already exists at \(configURL.path) (use --force to overwrite)")
        } else {
            try ConfigLoader.template().write(toFile: configURL.path, atomically: true, encoding: .utf8)
            print("wrote \(configURL.path)")
            print("next: set your repo in \(configURL.path), then `kinhin auth set`")
        }
    }
}
