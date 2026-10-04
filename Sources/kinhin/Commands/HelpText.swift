import Foundation
import KinhinKit

/// The full help screen, one call site for the printer and tests alike.
func helpText() -> String {
    """
    kinhin — autoscaling CI runners on your Mac: GitHub Actions, GitLab CI/CD, Gitea/Forgejo Actions, Buildkite, Azure Pipelines, and Bitbucket Pipelines.
    macOS jobs run on Tart VMs; Linux jobs on apple/container microVMs, Docker, or Tart Linux VMs

    USAGE:
        kinhin <command> [options]

    SETUP:
        config init                 Write a starter config file
        config validate             Check the config file without starting anything (exit 3 when invalid)
        auth [set]                  Store (or replace) your GitHub PAT in the Keychain (or: auth set --token)
        auth set --gitea            Store (or replace) your Gitea access token (auth set --gitea --token X)
        auth set --account NAME     Store the token for a named account (--token X to skip the prompt)
        auth add NAME --github|--gitlab|--gitea|--forgejo|--buildkite|--azuredevops|--bitbucket --scope S [--instance URL] [--token X]
                                    Add another account (GitHub, GitLab, Gitea, Forgejo, Buildkite, Azure DevOps or Bitbucket) to the config
        auth list                   List every account and whether its token is stored
        auth remove NAME            Remove an account from the config and delete its token
        auth status [--json]        Show whether a token is stored and valid (--json: all forges, machine output, exit 1 until ready)
        auth clear                  Remove the stored token
        doctor [--json]             Check prerequisites and print the computed capacity (--json: merged machine-readable diagnostics document)
        doctor --bundle [FILE]      Write a redacted support bundle (doctor report, config, recent log) to attach to a bug report
        setup-status [--json]       First-run checklist (pass --json for machine output)
        setup repair host-agent     Install the GitHub + Gitea runner agents for host runs (unisolated, on this Mac);
                                    gitlab-runner / buildkite-agent / the Azure Pipelines agent / the Bitbucket runner are added only when a GitLab / Buildkite / Azure DevOps / Bitbucket account is configured
        setup repair docker [--method desktop|orbstack|colima]
                                    Install Docker (default: the first method this Mac supports)
        setup repair container      Install Apple container and its system service (Apple silicon, macOS 26+)
        setup repair tart           Install tart for macOS VMs
        runtimes [--json]           Pools, capacity, budget, health, and routes (--no-health skips probes)
        runtimes route add <pat> <rt>   Route a repo (owner/repo) or workflow (owner/repo@Name) to tart|appleContainer|docker|host
                                    (host runs unisolated on this Mac and needs --consent)
        runtimes route remove <pat>     Delete that route; a running daemon reloads routing live
        image prepare [--provision-script <file>]
                                    Build the runner base image (slow, once): the runner
                                    agents plus your provision script. Toolchains are
                                    per project (see --project). Uses the shared host
                                    download cache (auto-pruned). Starts from base_image:
                                    (a pre-configured tart image or a local VM name)
                                    instead of the default macOS base
        image prepare --image <name>  Build one named image from the config's images:
                                    list (its own base_image:); --all builds image: and
                                    every images: entry, one after another
        image prepare --project <owner/name> [--ref <branch|tag>]
                                    Bake that repo's toolchains (its .kinhin.yml at --ref
                                    when the project sets repo_file, else the project's
                                    own toolchains:) into a derived image now, so its
                                    first job starts warm
        image prepare --container   Build the Linux container image (apple container):
                                    runner agents only; jobs install toolchains with
                                    `kinhin-toolchain install`
        image prepare --docker      Build the Linux container image (Docker Desktop /
                                    OrbStack / colima), agents only, the same way.
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
        toolchains                  Toolchain catalog, per-project selections, and cache state
        toolchains --project <owner/name> [--ref <branch|tag>]
                                    Show which toolchains that repo resolves to, where they
                                    come from, and the derived image they bake into
        toolchains detect [path] [--json] [--write] [--force]
                                    Scan a checkout and print the .kinhin.yml toolchains it
                                    needs, with the evidence (--write saves it; --force
                                    overwrites an existing file)
        toolchains list-images      Derived per-project images: size and last used
        toolchains prune [--dry-run]   Expire stale host-cache entries and unused derived images now
        image digest <registry>/<repo>:<tag>
                                    Print the digest the registry currently serves, so
                                    base_image: can be pinned to ref@sha256:… and every
                                    bake gets identical bits (a :latest tag may drift)
        toolchains helper [--linux]    Print the per-job `kinhin-toolchain` helper baked into images
        reset [--scope config|daemon|all] [--yes]
                                    Reset kinhin: config & credentials, the daemon install, or everything
                                    (VMs, images, cache and logs included). Asks twice; --yes skips the
                                    prompts. There is no undo

    WORKFLOW TESTING:
        workflow test [FILE] [--job NAME] [--list] [--json]
                                    Run a repo's GitHub Actions workflow locally on your
                                    Mac (host execution only). No VM, token or config:
                                    the YAML is parsed, jobs run sequentially in
                                    `needs` order, and each script step runs through
                                    bash. Defaults to `.github/workflows` in the repo;
                                    `--job NAME` runs one job (its needs are not run);
                                    `--list` prints the jobs; `--json` prints the
                                    final report instead of streaming
        workflow test --list        Print the jobs of the default workflow, then exit
        workflow test --json        Print the final report as JSON (exit 1 when a job failed)


    RUNNING:
        start                       Start the fleet in this terminal (Ctrl-C to stop)
        daemon                      Run the headless daemon in this terminal
        cleanup [--vms] [--image] [--cache] [--all] [--yes]
                                    Reclaim disk: leftover runner VMs, the base image, the toolchain cache.
                                    Reports only unless --yes is given (stop the fleet first)
        daemon install              Install and start a LaunchAgent daemon
        daemon uninstall            Stop and remove the LaunchAgent
        status [--json]             Show fleet status (attach to daemon if running; --json: machine-readable document with daemon/paused/autoResume fields)
        requeue <forge> [--yes]     Re-queue the fleet's queued jobs on a forge (confirm unless --yes)
        skip <forge> [--yes]        Mark the fleet's queued jobs as skipped on a forge (confirm unless --yes)
        pause | resume              Hold the fleet / let it scale again
        stop                        Stop the fleet (works on daemon or in-process)
        logs [-n N]                 Show recent log lines
        watch                       Live status view (refreshes every 2s)
        pipeline [VM] [--job NAME|ID] [--watch] [--json]
                                    Show the live pipeline a busy VM is running: its jobs and steps, with live
                                    timing. No VM: every busy VM. --job: just that job's steps. Needs the daemon
        pipeline [VM] [--job NAME|ID] --step N|NAME | --log [--follow] [--json]
                                    Print one step's (or the whole job's) output; --follow keeps streaming it

    OTHER:
        support                     Show ways to donate or sponsor kinhin
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
