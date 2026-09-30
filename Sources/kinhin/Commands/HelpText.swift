import Foundation
import KinhinKit

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
        auth add NAME --github|--gitea|--forgejo|--gitlab --scope S [--instance URL] [--token X]
                                    Add another account (GitHub, Gitea, Forgejo or GitLab) to the config
        auth list                   List every account and whether its token is stored
        auth remove NAME            Remove an account from the config and delete its token
        auth status [--json]        Show whether a token is stored and valid (--json: all forges, machine output, exit 1 until ready)
        auth clear                  Remove the stored token
        doctor [--json]             Check prerequisites and print the computed capacity (--json: merged machine-readable diagnostics document)
        setup-status [--json]       First-run checklist (pass --json for machine output)
        setup repair host-agent     Install the GitHub + Gitea runner agents for host runs (unisolated, on this Mac);
                                    gitlab-runner is added only when a GitLab account is configured
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
                                    shared host download cache (auto-pruned). Starts
                                    from base_image: (a pre-configured tart image or a
                                    local VM name) instead of the default macOS base
        image prepare --toolchain <spec> [--stack <name>]
                                    Override the config's toolchains for this prepare
        image prepare --container   Build the Linux container image (apple container);
                                    bakes `toolchains:` too — macOS-only entries are
                                    skipped (use --linux-toolchain/--linux-stack to override)
        image prepare --docker      Build the Linux container image (Docker Desktop /
                                    OrbStack / colima); bakes `toolchains:` the same way.
                                    --platform linux/amd64 bakes an x86_64 image that runs
                                    under emulation (slower; see docs)
        image prepare --linux --target <name> [--iso <file>] [--from <ref>]
                                    Create a Linux tart VM from scratch (tart create
                                    --linux) instead of cloning a prepared image: the VM
                                    boots with the arm64 ISO attached once, you install the
                                    OS by hand, then `image prepare --source <name>` bakes
                                    the agents into it. --from starts from a pre-configured
                                    image instead (tart.run's VM images; bare --from shows
                                    the menu)
        toolchains                  Managed-toolchain catalog, selections, and cache state
        toolchains prune [--dry-run]   Expire stale host-cache entries now
        image digest <registry>/<repo>:<tag>
                                    Print the digest the registry currently serves, so
                                    base_image: can be pinned to ref@sha256:… and every
                                    bake gets identical bits (a :latest tag may drift)
        toolchains helper [--linux]    Print the per-job `kinhin-toolchain` helper baked into images

    RUNNING:
        start                       Start the fleet in this terminal (Ctrl-C to stop)
        daemon                      Run the headless daemon in this terminal
        daemon install              Install and start a LaunchAgent daemon
        daemon uninstall            Stop and remove the LaunchAgent
        status [--json]             Show fleet status (attach to daemon if running; --json: machine-readable document with daemon/paused/autoResume fields)
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
