<p align="center"><img src="assets/brand/AppIcon.iconset/icon_128x128@2x.png" alt="kinhin" width="96"></p>

# kinhin ○

**The mindful CI — autoscaling runners that live on your Mac: GitHub Actions, GitLab CI/CD, Gitea/Forgejo Actions, Buildkite, Azure Pipelines, and Bitbucket Pipelines.**

> **Beta (`v0.0.1-beta-1`).** **GitHub Actions with Tart macOS VMs and Apple container** have been run for real. Docker,
> Tart Linux VMs, host mode, and every other forge (Gitea, Forgejo, GitLab, Buildkite, Azure DevOps, Bitbucket) are
> covered by unit tests against fakes and stubbed HTTP only, and have **never been run against a real server**. Expect
> surprises there, and please [report what you find](https://github.com/RabinApps/kinhin/issues/new/choose).
> See [what has been tested](docs/forges.md#what-has-been-tested) and the [roadmap to v0.1.0](docs/beta-roadmap.md).
> kinhin sends no telemetry. [Support kinhin](docs/support.md).

> ○ kinhin (kin-hin) is walking meditation: slow, deliberate steps between sittings.
> Here, one step at a time: a queued job arrives, a runner is born, serves, and is released.

kinhin runs [Tart](https://tart.run) macOS virtual machines on your Apple Silicon Mac — plus Linux jobs in
[apple/container](https://github.com/apple/container) microVMs, Docker containers, or Tart Linux VMs — and turns them
into ephemeral self-hosted CI runners. It watches your queues and grows or shrinks the fleet to match: a fresh VM (or
container) boots for each job, runs it, and is deleted. Host CPU, memory, and disk headroom are always reserved, so your
Mac stays usable. For fully trusted repos an opt-in [host mode](docs/runtimes.md#host-mode-run-jobs-directly-on-your-mac)
runs jobs directly on the Mac, with no isolation.

- **Ephemeral by default** — every job gets a freshly cloned VM; no state leaks between jobs.
- **Multi-forge, multi-runtime** — seven forges and four runtimes in one fleet, routed per repo, workflow, or `runs-on:`
  label ([Forges](docs/forges.md), [Runtimes & routing](docs/runtimes.md)).
- **Fast, dense, resource-aware** — linked clones boot in seconds, an opt-in [warm pool](docs/scaling.md#warm-pool)
  (`warm_pool`) keeps booted VMs waiting so jobs skip the boot, `runners_per_vm` packs small jobs onto one VM, and the
  scaler never exceeds what your Mac can handle (`kinhin doctor`). Why: [Why kinhin](docs/why.md).
- **Toolchains your way** — bake, pin per repo, or install per job ([Toolchains](docs/toolchains.md)).
- **App, menu bar, or headless daemon** — same engine, same config ([The app](docs/app.md)).

## Requirements

- Apple Silicon Mac, macOS 15+, ~60 GB free disk ([sizing](docs/hardware.md)), and an access token for a
  [forge](docs/forges.md) (e.g. a GitHub PAT with `repo` scope)
- Tart for macOS jobs (kinhin installs it, see below); Linux jobs are optional ([runtimes](docs/runtimes.md#choosing-a-linux-runtime))

## Install

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

The script verifies the signed, notarized DMG, installs **kinhin.app**, and links the `kinhin` CLI. Pinned versions,
air-gapped installs, uninstall and update checks: [Install](docs/install.md). Tart is installed by
`kinhin setup repair tart` (or the app's setup window); manual brew commands live in
[Installing Tart](docs/install.md#installing-tart).

## Quick start

```bash
kinhin setup repair tart                 # 1. install tart (no-op if present); then `kinhin doctor` checks the Mac
kinhin config init                       # 2. starter config: set the accounts: entry (name/forge/scope) and labels
kinhin auth set                          #    store your token in the Keychain (--gitlab, --gitea, … for other forges)
kinhin image prepare && kinhin start     # 3. bake the runner image once, then run the fleet (or `kinhin daemon install`)
```

Point a workflow at it (`runs-on` must include every configured label) and watch with `kinhin watch`:

```yaml
jobs:
  build:
    runs-on: [self-hosted, macos, arm64]
```

Prefer a GUI? Launch **kinhin** from Applications; its setup wizard does the same. Details:
[Quick start](website/guide/quick-start.md), [The kinhin app](docs/app.md), [Configuration](website/guide/config.md).

## Documentation

[Why](docs/why.md) · [Install](docs/install.md) · [Security](docs/security.md) · [App](docs/app.md) ·
[Hardware](docs/hardware.md) · [Scaling](docs/scaling.md) · [Requeue/skip](docs/requeue-skip.md) ·
[Toolchains](docs/toolchains.md) · [Forges](docs/forges.md) ([API](docs/forges/README.md)) · [Runtimes](docs/runtimes.md) ·
[Workflow testing](docs/workflow-testing.md) · [Agents & MCP](docs/agents.md) · [Architecture](docs/architecture.md) ·
[Troubleshooting](website/guide/troubleshooting.md) · [Roadmap](docs/beta-roadmap.md)

## Commands

<!-- docs-sync:begin cli-help -->

```
kinhin config init          Write the starter config
kinhin config validate [--json] Check the config file without starting anything (exit 3 when invalid;
                             --json: machine-readable valid/error document)
kinhin auth set|status|clear   (set/replace PAT; a running daemon picks it up live)
kinhin auth add|list|remove    Manage additional accounts (GitHub, GitLab, Gitea, Forgejo, Buildkite, Azure DevOps, Bitbucket; auth set --account NAME stores one's token)
kinhin auth status --json    All forges' stored-token state in one machine-readable document (exit 1 until ready)
kinhin doctor [--json]      Prerequisites + computed capacity (--json: host, runtime health, stored tokens, checklist,
                             and capacity in one machine-readable document; ready=false until every half passes)
kinhin doctor --bundle [FILE]  Write a redacted support bundle (doctor report, config, recent log) to attach to a bug report
kinhin setup-status [--json] First-run checklist; exit 1 until ready (--json for scripts)
kinhin runtimes [--json]    Pools, capacity, budget split, live health, and routes (--no-health skips probes)
kinhin runtimes route add <pattern> <tart|appleContainer|docker|host> [--consent]
                             Route a repo (`owner/repo`) or workflow (`owner/repo@Name`) — same validated
                             editor as the Advanced → Routing tab; a running daemon reloads routing live.
                             `host` runs jobs unisolated on this Mac and requires --consent
kinhin runtimes route remove <pattern>
                             Delete that route (e.g. `acme/api` or `acme/web@Nightly`)
kinhin setup repair host-agent
                             Install the GitHub + Gitea runner agents for host routes (one time); gitlab-runner,
                             buildkite-agent, the Azure Pipelines agent or the Bitbucket runner is added too when
                             a GitLab, Buildkite, Azure DevOps or Bitbucket account is configured
kinhin image prepare        Build the runner base image (once); --provision-script <file>
                             bakes your tools in (see docs/toolchains.md); bakes only the base
                             image (agents + provision script), never per-project toolchains;
                             starts from top-level `base_image:` when set
kinhin image prepare --linux --target <name> [--from <ref>]
                             Create a Linux tart VM from scratch; --from starts it from a
                             pre-configured image (bare --from shows the menu) instead of an ISO
kinhin image digest <registry>/<repo>:<tag>
                             Print the digest the registry currently serves, so base_image:
                             can be pinned to ref@sha256:… and bakes stay reproducible
kinhin image list [--json] [--runtime tart|container|docker]
                             Show every installed image (tart, apple container, Docker):
                             role, size, last used, and who is using it; --runtime narrows
                             the listing to one runtime
kinhin image delete <name>… [--yes]
                             Delete installed images by name, in every runtime that holds
                             them; reports only unless --yes is given
kinhin image prune [--yes]   One pass: sweep stale derived-image records and delete local
                             images nothing uses; reports only unless --yes is given, and
                             never touches configured images, the base_image or images in use
kinhin image prepare --project <owner/name> [--ref <ref>]
                             Bake the derived image (macOS/tart) for a repo's resolved toolchains now
kinhin toolchains           Managed-toolchain catalog, selections, shared-cache state
kinhin toolchains --project <owner/name> [--ref <ref>]
                             Show a repo's effective toolchains, where they came from, and its image key
kinhin toolchains detect [path] [--json] [--write] [--force]
                             Scan a local checkout and generate its `.kinhin.yml` toolchains block, with evidence
kinhin toolchains list-images
                             Derived per-project images: size and last used
kinhin toolchains prune [--dry-run]
                             Expire stale host-cache entries now
kinhin toolchains helper [--linux]
                             Print the per-job `kinhin-toolchain` helper present in images
kinhin workflow test [FILE] [--job NAME] [--list] [--lenient] [--json]
                             Run GitHub Actions workflow scripts on this Mac (host-only); see docs/workflow-testing.md
kinhin workflow route <FILE|name> <tart|appleContainer|docker|host>
                             Route the workflow's runs-on: to that runtime — edits the workflow (comment-preserving)
                             and reconciles the config route when precedence needs it; see docs/runtimes.md
kinhin start                Run the fleet in the foreground
kinhin daemon               Run the daemon in the foreground
kinhin daemon install       Install + start the LaunchAgent
kinhin daemon uninstall     Remove the LaunchAgent
kinhin status|watch         Fleet status
kinhin pause|resume         Hold the fleet / resume scaling
kinhin stop                 Stop the fleet
kinhin requeue <forge> [--yes]  Re-queue the fleet's queued jobs on a forge (confirm unless --yes)
kinhin skip <forge> [--yes]     Mark the fleet's queued jobs as skipped on a forge (confirm unless --yes)
kinhin reset [--scope config|daemon|all] [--yes]
                            Reset kinhin: config & credentials, the daemon install, or everything (VMs, images,
                            cache, logs included). Confirms twice; --yes skips the prompts. There is no undo
kinhin logs [-n N]          Recent log lines
kinhin mcp                  Serve MCP over stdio for AI agents: tools/list + tools/call expose status,
                            doctor, runtimes, pipeline, logs and pause/resume/stop as JSON
kinhin support              Show ways to donate or sponsor kinhin
```

<!-- docs-sync:end cli-help -->

## Contributing and support

`swift build` and `swift test` need no VMs or network; conventions, the debug-app workflow and `scripts/check.sh` are in
[CONTRIBUTING.md](CONTRIBUTING.md). kinhin is free, with no ads and no telemetry; [support it](docs/support.md) or
[add your project to the list](docs/used-by.md). More from Rabin Apps: [SupDesk](https://supdesk.app/en).

## License

Copyright © 2026 Rabin Apps, LLC. Licensed under the [Apache License 2.0](LICENSE).
kinhin shells out to [Tart](https://tart.run) and links [Yams](https://github.com/jpsim/Yams) (both Apache-2.0); see [NOTICE](NOTICE).
