# CLI commands

```
kinhin config init          Write the starter config
kinhin auth set|status|clear   (set/replace PAT; a running daemon picks it up live)
kinhin auth set --gitea     Store/replace the Gitea access token
kinhin auth add NAME --github|--gitlab|--gitea|--forgejo|--buildkite|--azuredevops --scope S [--instance URL] [--token X]   Add another account (any forge) to config.yaml
kinhin auth set --account NAME   Store/replace that account's token (also: status/clear --account NAME)
kinhin auth list            Every account and whether its token is stored
kinhin auth remove NAME     Remove an account and its token
kinhin auth status --json   All forges' stored-token state in one machine-readable document (exit 1 until ready)
kinhin doctor [--json]      Prerequisites + computed capacity (--json: host, runtime health, stored tokens, checklist,
                            and capacity in one machine-readable document; ready=false until every half passes)
kinhin setup-status [--json] First-run checklist; exit 1 until ready (--json for scripts)
kinhin runtimes [--json]    Pools, capacity, budget split, live health, and routes (--no-health skips probes)
kinhin runtimes route add <pattern> <tart|appleContainer|docker>
                            Route a repo (`RabinApps/repo`) or workflow (`RabinApps/repo@Name`) — same validated
                            editor as the Advanced → Routing tab; a running daemon reloads routing live
kinhin runtimes route remove <pattern>
                            Delete that route (e.g. `acme/api` or `acme/web@Nightly`)
kinhin image prepare        Build the runner base image (once); --provision-script <file>
                            bakes your toolchains in; `toolchains:` config entries are baked
                            automatically and downloads go through a shared host cache (auto-pruned);
                            starts from top-level `base_image:` when set (a pre-configured tart
                            image or a local VM name; default macOS base otherwise)
kinhin image prepare --toolchain <spec> [--stack <name>]
                            Override the config's toolchains for this prepare
kinhin image prepare --container
                            Build the Linux container image (apple container)
kinhin image prepare --docker
                            Build the Linux container image (Docker Desktop / OrbStack / colima)
kinhin image prepare --linux --target <name> [--from <ref>]
                            Create a Linux tart VM from scratch; --from starts it from a
                            pre-configured image (bare --from shows the menu) instead of an ISO
kinhin image digest <registry>/<repo>:<tag>
                            Print the digest the registry currently serves, so base_image: can
                            be pinned to ref@sha256:… and every bake gets identical bits
kinhin toolchains           Managed-toolchain catalog, selections, shared-cache state
kinhin toolchains prune [--dry-run]
                            Expire stale host-cache entries now
kinhin start                Run the fleet in the foreground
kinhin daemon               Run the daemon in the foreground
kinhin daemon install       Install + start the LaunchAgent
kinhin daemon uninstall     Remove the LaunchAgent
kinhin status --json        Fleet status as a machine-readable document (daemon/paused/autoResume fields; watch streams prose)
kinhin pause|resume         Hold the fleet / resume scaling
kinhin stop                 Stop the fleet
kinhin logs [-n N]          Recent log lines
kinhin version              Print version
kinhin help                 Show help
```

## How scaling works

Every `poll_interval` seconds the engine:

1. Cleans up any failed instances from the previous pass.
2. Asks each forge for queued jobs on its scope and filters them by `labels`.
3. **Routes** each job to a runtime — workflow route → repo route → `runs-on:` label → default —
   and buckets the demand per pool.
4. Computes the desired instance count **per pool**:
   `desired = clamp(ceil(pool_queue / runners_per_vm), min_runners, pool_cap)`.
5. Spawns instances up to `desired` (linked clone → boot → SSH → register `runners_per_vm`
   runners → `run.sh`) — Tart VMs for macOS pools, containers for Linux pools.
6. Deletes idle instances when `desired` drops (scale to zero by default).

Runners register `--ephemeral`, so the forge removes the registration as soon as the job
finishes; kinhin then deletes the VM. If the engine crashes or restarts it reconciles
`tart list` against its persisted state, adopts orphaned VMs, and drops records whose VMs
vanished.

Registration tokens are short-lived (1 h); kinhin caches and refreshes them automatically.
Your PAT lives in the login Keychain.
