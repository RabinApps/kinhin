# CLI commands

<!-- docs-sync:begin cli-help -->
```text
kinhin — autoscaling CI runners on your Mac.
Tart VMs run macOS jobs; apple/container, Docker or Tart Linux VMs run Linux jobs.
Forges: GitHub Actions, GitLab CI/CD, Gitea, Forgejo (Buildkite, Azure, Bitbucket planned).

USAGE:
    kinhin                                  Setup status and the next step
    kinhin <command> [options]
    kinhin <command> --help                 Options for one command

SETUP:
    config init                             Write a starter config file
    config validate                         Check the config without starting anything
    config migrate                          Translate removed config keys to the current schema
    config export [FILE]                    Write the config for another Mac (no tokens)
    config import FILE                      Use a config exported on another Mac
    auth set                                Store (or replace) a token in the Keychain
    auth add NAME                           Add an account to the config
    auth list                               List accounts and whether their tokens are stored
    auth remove NAME                        Remove an account and delete its token
    auth status                             Check that stored tokens exist and work
    auth clear                              Remove a stored token
    doctor                                  Check prerequisites and the computed capacity
    setup status                            Show the first-run checklist
    setup repair host-agent                 Install the runner agents for host runs
    setup repair docker                     Install Docker
    setup repair container                  Install Apple container and its service
    setup repair tart                       Install tart for macOS VMs
    runtimes                                Pools, capacity, budget, health and routes
    runtimes route add <pattern> <runtime>  Route a repo or workflow to a runtime
    runtimes route remove <pattern>         Delete a route

IMAGES AND TOOLCHAINS:
    image prepare                           Build the runner base image (slow, once)
    image list                              Show installed images, their size and who uses them
    image delete <name>…                    Delete installed images by name
    image prune                             Sweep stale records and delete unused local images
    image digest <registry>/<repo>:<tag>    Print the digest a registry serves, to pin base_image
    toolchains                              Toolchain catalog, project selections and cache state
    toolchains detect [path]                Scan a checkout for the toolchains it needs
    toolchains list-images                  Derived per-project images: size and last used
    toolchains prune                        Expire stale cache entries and unused derived images
    toolchains helper                       Print the per-job kinhin-toolchain helper script
    mobile                                  Set up fastlane store releases for a mobile app
    mobile init [DIR]                       Add fastlane lanes and the CI release workflow

RUNNING:
    start                                   Start the fleet in this terminal (Ctrl-C to stop)
    daemon                                  Run the headless daemon in this terminal
    daemon install                          Install and start a LaunchAgent daemon
    daemon uninstall                        Stop and remove the LaunchAgent
    status                                  Show fleet status (attaches to the daemon)
    pause                                   Hold the fleet: no new runners start
    resume                                  Let a paused fleet scale again
    stop                                    Stop the fleet (works on a daemon)
    logs                                    Show recent log lines
    watch                                   Live status view (refreshes every 2s)
    pipeline [VM]                           Live jobs and steps of the VMs that are busy
    requeue <forge>                         Re-queue the fleet's queued jobs on a forge
    skip <forge>                            Mark the fleet's queued jobs as skipped on a forge
    cleanup                                 Reclaim disk: leftover VMs, the base image, the cache
    bench [SUITE]…                          Benchmark runtimes, workloads and toolchains here
    reset                                   Reset config, the daemon install, or everything

WORKFLOWS:
    workflow test [FILE]                    Run a workflow locally on this Mac (host execution)
    workflow route <FILE|name> <runtime>    Route a workflow's jobs to a runtime

OTHER:
    video init [name]                       Create a starter video in .kinhin/videos/
    video list                              List the videos in .kinhin/videos/
    video build [name]                      Build a video from its config
    video theme list                        List the built-in themes and yours
    video theme new <name>                  Write a starter theme file
    video music search <words>              Search openly licensed music
    video music preview <number|id>         Listen to a search result
    video music add <number|id|name>        Download a track into the repository and use it
    video music list                        Show the music each video uses
    support                                 Show ways to donate or sponsor kinhin
    issue                                   Submit an issue on GitHub
    mcp                                     Serve MCP over stdio for AI agents
    version                                 Print the version
    help [command]                          Show this help, or `help <command>` for one command

EXIT CODES:
    0 ok    1 needs attention    2 usage error    3 config    4 runtime    5 auth

Add --json for machine-readable output. Docs: https://github.com/RabinApps/kinhin/tree/main/docs
```
<!-- docs-sync:end cli-help -->

## Exit codes

Scripts can branch on the exit code.

<!-- docs-sync:begin exit-codes -->
| Code | Meaning |
|---|---|
| 1 | Needs attention (not healthy), or anything unclassified |
| 2 | Bad command line |
| 3 | Invalid or unreadable config |
| 4 | Runtime or engine failure |
| 5 | Missing or rejected token |
| 130 | Cancelled (Ctrl-C); in-progress work was cleaned up |
<!-- docs-sync:end exit-codes -->

## How scaling works

Every `poll_interval` seconds the engine:

1. Cleans up any failed instances from the previous pass.
2. Asks each forge for queued jobs on its scope and filters them by `labels`.
3. **Routes** each job to a runtime — workflow route → repo route → `runs-on:` label → default —
   and buckets the demand per pool.
4. Computes the desired instance count **per pool**:
   `desired = clamp(ceil(pool_queue / runners_per_vm), min_runners, pool_cap)`.
5. Spawns instances up to `desired` (linked clone → boot → SSH → register `runners_per_vm`
   runners → `run.sh`) — Tart VMs for macOS and Tart-Linux pools, containers for the container
   Linux pools (see [Runtimes & routing](/guide/runtimes#choosing-a-linux-runtime)).
6. Deletes idle instances when `desired` drops (scale to zero by default).

Runners register `--ephemeral`, so the forge removes the registration as soon as the job
finishes; kinhin then deletes the VM. If the engine crashes or restarts it reconciles
`tart list` against its persisted state, adopts orphaned VMs, and drops records whose VMs
vanished.

Registration tokens are short-lived (1 h); kinhin caches and refreshes them automatically.
Your PAT lives in the login Keychain.
