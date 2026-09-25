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
        print(
            "warning: could not notify running daemon (\(error.localizedDescription)); restart it to pick up the new token"
        )
    }
}

/// Same best-effort notification for the Gitea token.
func notifyDaemonGiteaTokenReplaced(_ token: String) {
    guard RPCClient.isDaemonAlive() else { return }
    do {
        try RPCClient().replaceGiteaToken(token)
        print("running daemon notified — new Gitea token is live")
    } catch {
        print(
            "warning: could not notify running daemon (\(error.localizedDescription)); restart it to pick up the new token"
        )
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("kinhin: \(message)\n".utf8))
    exit(1)
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
        auth status [--json]        Show whether a token is stored and valid (--json: all forges, machine output, exit 1 until ready)
        auth clear                  Remove the stored token
        doctor [--json]             Check prerequisites and print the computed capacity (--json: merged machine-readable diagnostics document)
        setup-status [--json]       First-run checklist (pass --json for machine output)
        runtimes [--json]           Pools, capacity, budget, health, and routes (--no-health skips probes)
        runtimes route add <pat> <rt>   Route a repo (owner/repo) or workflow (owner/repo@Name) to tart|appleContainer|docker
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
                                    OrbStack / colima); bakes `toolchains:` the same way
        toolchains                  Managed-toolchain catalog, selections, and cache state
        toolchains prune [--dry-run]   Expire stale host-cache entries now

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

func printHelp() {
    print(helpText())
}

func loadConfigOrExit() -> kinhinConfig {
    do {
        let cfg = try ConfigLoader.load()
        return cfg
    } catch {
        fail(error.localizedDescription)
    }
}

/// The token the engine is built with: the GitHub PAT, or an empty
/// placeholder for a Gitea-only config (whose own token is required instead).
func tokenOrExit(for cfg: kinhinConfig) -> String {
    guard let token = ConfigLoader.engineToken(for: cfg) else {
        fail(
            cfg.githubEnabled
                ? "no GitHub token stored. Run: kinhin auth set"
                : "no Gitea token stored. Run: kinhin auth set --gitea")
    }
    return token
}

func engineFromConfig(_ cfg: kinhinConfig) throws -> FleetEngine {
    // The auto-created template parses cleanly but names a placeholder repo —
    // never boot a fleet (and start polling GitHub) against it.
    if !ConfigLoader.hasAnyForge(cfg) {
        fail("config has no forge yet — set your repo (or a gitea: section) in \(Paths.config.path) first")
    }
    let tart = try cfg.makeTartControlling()
    let github = GitHubClient(credentials: GitHubCredentials(token: tokenOrExit(for: cfg), scope: cfg.repo))
    let host = ResourceProbe().snapshot()
    return FleetEngine(
        config: cfg,
        github: github,
        tart: tart,
        store: FleetStore(),
        ssh: SSHExecutor(),
        host: host
    )
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
