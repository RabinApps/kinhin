# kinhin ○

**The mindful CI — autoscaling runners that live on your Mac: GitHub Actions, GitLab CI/CD, Gitea/Forgejo Actions, Buildkite, Azure Pipelines, and Bitbucket Pipelines.**

> **Beta (`v0.0.1-beta-1`).** Only **GitHub Actions with Tart macOS VMs** has been run for real. Every other
> forge (Gitea, Forgejo, GitLab, Buildkite, Azure DevOps, Bitbucket) and runtime (apple/container, Docker, host)
> is covered by unit tests against fakes and stubbed HTTP only, and has **never been run against a real server**.
> Expect surprises there, and please [report what you find](https://github.com/RabinApps/kinhin/issues/new/choose).
> See [what has been tested](docs/forges.md#what-has-been-tested) and the [roadmap to v0.1.0](docs/beta-roadmap.md).
> kinhin sends no telemetry.
>
> [Support kinhin](docs/support.md).

> ○ kinhin (kin-hin) is walking meditation: slow, deliberate steps between sittings.
> Here, one step at a time: a queued job arrives, a runner is born, serves, and is released.

kinhin runs [Tart](https://tart.run) macOS virtual machines on your Apple Silicon Mac — plus
Linux jobs in [apple/container](https://github.com/apple/container) microVMs, in Docker
containers, or in full Tart Linux VMs — and turns them into ephemeral self-hosted CI runners. It watches your repositories'
queued jobs and grows or shrinks the fleet to match — a fresh VM (or container) boots for each
job, runs it, and is deleted. For repos you fully trust, an opt-in **host** mode runs jobs directly
on your Mac instead — no VM, no isolation (see [Host mode](docs/runtimes.md#host-mode-run-jobs-directly-on-your-mac)).  
Your Mac stays usable: host CPU, memory, and disk headroom are always reserved.

```
┌─────────────────────────── your Mac ───────────────────────────┐
│  menu bar ○  ── FleetEngine ── poll forges (queued jobs)         │
│                     │   GitHub · GitLab · Gitea · Buildkite     │
│   routes each job: repo/workflow → Tart VM, container, or host  │
│     ┌───────────────┬───────────────┬─────────────────┐         │
│   tart VM #1    tart VM #2    🐧 container #1 … (up to cap)     │
│   macOS jobs    macOS jobs    Linux jobs    runners_per_vm/VM   │
└─────────────────────────────────────────────────────────────────┘
```

- **Ephemeral by default** — every job gets a freshly cloned VM; the runner deregisters itself
  afterwards and the VM is deleted. No state leaks between jobs.
- **Multi-forge** — GitHub Actions, GitLab CI/CD, Gitea Actions, Forgejo, Buildkite, Azure Pipelines, and Bitbucket Pipelines from the same pool; the Forge
  abstraction keeps the door open for other platforms (see [Forge support](docs/forges.md)).
- **Multi-runtime** — macOS jobs run in Tart VMs, Linux jobs in [apple/container](https://github.com/apple/container)
  microVMs, Docker containers, or full Tart Linux VMs, from one fleet: each job is routed by repo, workflow, or `runs-on:` label, and the host
  budget is partitioned across the pools so neither can overcommit your Mac (see
  [Runtimes & routing](docs/runtimes.md)). Trusted repos can opt in to
  [host mode](docs/runtimes.md#host-mode-run-jobs-directly-on-your-mac): jobs run directly on your Mac, unisolated.
- **Many jobs per VM** — `runners_per_vm` registers several runner processes on one Tart VM, so
  small jobs share a VM instead of each paying a full boot.
- **Fast** — VMs are linked clones of one prepared base image, so boots take seconds, not minutes.
- **Resource-aware** — the scaler never exceeds what your Mac can handle (see `kinhin doctor`).
- **Toolchains your way** — bake them into the image, let kinhin install and pin them, or install
  per job, or let each repo pin its own versions in a `.kinhin.yml` (`kinhin toolchains detect` generates one
  from your manifests and CI workflows), with a shared download cache (see [Toolchains](docs/toolchains.md)). `kinhin toolchains detect` writes that `.kinhin.yml` for you
  by scanning a checkout.
- **App, menu bar, or headless** — a main window, a classic tray app, or a LaunchAgent daemon;
  same engine, same config (see [The kinhin app](docs/app.md)).
- **One-line install** — `curl … | bash` from GitHub Releases, with daily update checks.

## Why kinhin

Every CI platform's self-hosted runner works one job at a time: register one on your Mac and the rest of
the queue waits. GitHub [assigns a single job to each ephemeral runner](https://docs.github.com/en/actions/reference/runners/self-hosted-runners),
Gitea's `act_runner` defaults to [`capacity: 1`](https://gitea.com/gitea/act_runner/src/branch/main/internal/pkg/config/config.example.yaml),
[Buildkite](https://buildkite.com/docs/agent/cli-start) and [Azure Pipelines](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/agents)
scale by adding agents, and macOS itself [limits a Mac to two macOS VMs](https://eclecticlight.co/2022/08/04/virtualisation-on-apple-silicon-macs-8-how-apple-limits-vms/).
kinhin fixes that: it watches your queues and boots a fresh, isolated runner per job, so jobs run
concurrently without leaking state. Full write-up with sources: [Why kinhin](docs/why.md).

## Requirements

- Apple Silicon Mac (arm64), macOS 15+
- [Tart](https://tart.run):
  ```bash
  brew tap openai/tools
  brew trust openai/tools
  brew install openai/tools/tart
  ```
- A GitHub PAT with `repo` scope for the repository you want to serve (or a GitLab, Gitea/Forgejo,
  Buildkite, Azure DevOps or Bitbucket access token if you only use those — see [Forge support](docs/forges.md))
- Optional — Linux jobs. Three options (see [Runtimes](docs/runtimes.md#choosing-a-linux-runtime) for the
  comparison): [apple/container](https://github.com/apple/container) microVMs
  (`brew install container && container system start`), Docker containers, or full Tart Linux VMs —
  the last needs nothing beyond tart itself, which macOS jobs require anyway
- ~60 GB free disk for the base image plus per-VM scratch

Sizing a fleet for your Mac — CPU, memory, and storage recommendations — is covered in
[Hardware requirements & sizing](docs/hardware.md).

## Install

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

The script sha256-verifies the release DMG, copies **kinhin.app** to /Applications, and symlinks
the `kinhin` CLI into your bin dir — the first writable of /opt/homebrew/bin, /usr/local/bin, and
~/.local/bin. Releases are Developer ID signed and notarized. Remove
everything with `bash scripts/install.sh --uninstall` (config and your Keychain PAT are kept).
Pinned versions, air-gapped installs, and update checks are covered in
[docs/install.md](docs/install.md).

## Quick start (CLI)

```bash
# 1. Install tart (skipped automatically if tart is already on your PATH)
brew tap openai/tools
brew trust openai/tools
brew install openai/tools/tart

# 2. Create a starter config
kinhin config init
#    edit ~/Library/Application Support/Kinhin/config.yaml
#    -> set the accounts: entry (name/forge/scope) and the labels jobs will request

# 3. Store a GitHub PAT (repo scope) — it goes in your Keychain, not a file
kinhin auth set

# 4. Check prerequisites and see how many VMs your Mac can host
kinhin doctor

# 5. Prepare the runner base image (once; downloads + provisions a VM, takes a while)
kinhin image prepare

#    Manual equivalent of what `image prepare` automates:
#      tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest tahoe-base
#      tart run tahoe-base
#    (then the runner agent is injected over SSH; `kinhin image prepare` does all of it,
#     including checking whether tart/the image already exist before downloading)

# 6. Point your config at the prepared image
#    image: "tahoe-base"

# 7. Go
kinhin start          # foreground, Ctrl-C to stop
# or
kinhin cleanup [--vms] [--image] [--cache] [--all] [--yes] [--json]
                            Reclaim disk: leftover runner VMs, the base image, the toolchain cache. Reports only
                            unless --yes is given (stop the fleet first); --json is the dry-run report and
                            refuses --yes
kinhin reset [--scope config|daemon|all] [--yes]
                            Start over: credentials only, the daemon, or everything — confirms twice, no undo
kinhin daemon install # headless LaunchAgent, survives reboots
```

Dispatch a workflow whose job matches your labels:

```yaml
jobs:
  build:
    runs-on: [self-hosted, macos, arm64] # must include all configured labels
    steps:
      - run: uname -m # arm64 — you're running on your own Mac
```

Watch the fleet: `kinhin watch` (live) or `kinhin status` (one shot).

## Quick start (menu bar app)

Install with the one-liner above, then launch **kinhin** from Applications. The setup window walks
through the same steps as the CLI — installing tart, creating the config, storing the token, and
preparing the image — then starts the fleet. The main window has **Fleet**, **Setup**, and
**Advanced** tabs, and the ○ in your menu bar shows the number of live runner VMs. See
[The kinhin app](docs/app.md) for launch modes, Siri & Shortcuts, and running alongside the daemon.

## Configuration

`~/Library/Application Support/Kinhin/config.yaml` — full template via `kinhin config init`.
Key fields:

| Field                                      | Meaning                                                                                                                                                                                                   |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `repo`                                     | GitHub scope to serve: `owner/name` for one repo, or a bare org name for org-level runners that serve **every repo in the organization** (PAT needs org runner-admin permission)                          |
| `labels`                                   | Jobs must request _all_ of these to be picked up                                                                                                                                                          |
| `min_runners` / `max_runners`              | Scaling bounds (in VMs)                                                                                                                                                                                   |
| `runners_per_vm`                           | Runner processes per VM — many-to-one job density (1–8; 1 = one job per VM, most isolated)                                                                                                                |
| `poll_interval`                            | Seconds between GitHub polls (≥ 5)                                                                                                                                                                        |
| `vm.cpu` / `vm.memory_gb` / `vm.ephemeral` | Per-VM shape                                                                                                                                                                                              |
| `image`                                    | Tart image cloned per runner (`tahoe-base` after prepare)                                                                                                                                                 |
| `base_image`                               | What `image prepare` starts from: a pre-configured tart image (`ghcr.io/cirruslabs/...`), digest-pinned (`ref@sha256:…` — see `kinhin image digest`), or a local VM name; absent = the default macOS base |
| `provision_script`                         | Host script baked into the image by `image prepare` (your toolchains; see [Baking toolchains](docs/toolchains.md#bake-tools-into-the-base-image))                                                         |
| `projects`                                 | Per-repo toolchains: `repo_file: true` honors the repo's `.kinhin.yml`; `toolchains`, `share_cache` per entry (see [Per-project toolchains](docs/toolchains.md#per-project-toolchains))                   |
| `reserve.cpu` / `reserve.memory_gb`        | Host headroom kept free                                                                                                                                                                                   |
| `reserve.disk_gb`                          | Host disk (GB) kept free (default 10)                                                                                                                                                                     |

The effective concurrency cap is the smallest of `max_runners` and what your Mac's CPU, memory,
and disk can hold after the `reserve` headroom; `kinhin doctor` prints the cap and the binding
constraint. See [How scaling works](docs/scaling.md) for the formula and the scaling loop.
Serving the same repo from more than one Mac? Give each Mac its own label so only one spawns for a
job: [Running on multiple Macs](docs/scaling.md#running-on-multiple-macs).

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
kinhin workflow test [FILE] [--job NAME] [--list] [--json]
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

## Documentation

| Doc                                                  | Covers                                                                                                                                                     |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Why kinhin](docs/why.md)                            | The one-job-per-runner problem and how kinhin solves it, with sources                                                                                      |
| [Install](docs/install.md)                           | Install script, air-gapped installs, update checks                                                                                                         |
| [Security](docs/security.md)                         | Threat model, hardening for untrusted PRs, what kinhin enforces                                                                                            |
| [The kinhin app](docs/app.md)                        | Main window tabs, launch modes, Siri & Shortcuts, app + daemon together                                                                                    |
| [Hardware requirements & sizing](docs/hardware.md)   | Minimum specs and CPU / memory / storage recommendations                                                                                                   |
| [How scaling works](docs/scaling.md)                 | Capacity cap, the scaling loop, `runners_per_vm`, recovery                                                                                                 |
| [Requeue and skip queued jobs](docs/requeue-skip.md) | Per-fleet queue operations: (re)queue, skip, per-forge scope, CLI (`kinhin requeue <forge> [--yes]` / `kinhin skip <forge> [--yes]`), and failure handling |
| [Toolchains & the shared cache](docs/toolchains.md)  | Provision scripts, managed and per-project toolchains, per-job installs, the download cache                                                                |
| [Support & sponsors](docs/support.md)                | Donate, or become a paid sponsor                                                                                                                           |
| [Forge support](docs/forges.md)                      | GitHub, GitLab, Gitea, Forgejo, Buildkite, Azure DevOps, Bitbucket, multiple accounts                                                                      |
| [Forge API reference](docs/forges/README.md)         | Per-forge endpoints, auth, API versions and an audit against each forge's docs                                                                             |
| [Runtimes & routing](docs/runtimes.md)               | Tart, Apple `container`, Docker, host mode, per-repo/per-workflow routing                                                                                  |
| [Test workflows locally](docs/workflow-testing.md)   | Run a supported subset of GitHub Actions scripts on your Mac                                                                                               |
| [AI agents & MCP](docs/agents.md)                    | Skills, the MCP server, every `--json` surface, and the safety rules for agents                                                                            |
| [Architecture](docs/architecture.md)                 | Package targets, source layout, tests, CI                                                                                                                  |

## Troubleshooting

- **`kinhin doctor` shows "tart: NOT FOUND"** — install tart with `brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart`, then reopen
- **\"tart: INSTALLED BUT KILLED ON LAUNCH ✗\"** — the OpenAI-tap bottle is un-notarized (openai/homebrew-tools#27); Gatekeeper kills it before it runs. Roll back to the notarized Cirrus Labs build — `kinhin doctor` and the setup app print/offer the exact commands:
  ```bash
  brew uninstall openai/tools/tart openai/tools/softnet
  brew tap cirruslabs/cli
  brew trust cirruslabs/cli
  brew install cirruslabs/cli/tart
  ```
  Re-run `kinhin doctor` afterwards; it will offer to move back to the OpenAI tap once a fixed bottle ships.
- **Jobs queue but no VMs start** — check that the job's `runs-on:` contains _every_ label in your
  config; the scaler only counts jobs it could actually run.
- **VM boots but the runner never registers** — the base image may predate the injected agent.
  Re-run `kinhin image prepare`. Full logs: `kinhin logs -n 200` or
  `~/Library/Application Support/Kinhin/logs/kinhin.log`.
- **Token rejected** — re-run `kinhin auth set`; the PAT needs `repo` scope and access to the repo.
- **First launch blocked** — only applies to old releases or locally built copies (official
  releases are signed and notarized). Right-click → Open, or `xattr -cr /Applications/kinhin.app`.

## Contributing

`swift build` and `swift test` need no VMs or network. Conventions (layout, style, error handling,
formatting) are in [CONTRIBUTING.md](CONTRIBUTING.md); the package layout is in
[docs/architecture.md](docs/architecture.md). If you touch shared state or concurrency, also run `scripts/tsan.sh`
([how to read it](docs/architecture.md#debugging-races-with-threadsanitizer)).

To run the debug app, use `scripts/dev-run.sh` rather than the bare binary: it signs the build with a stable
identity (your first Apple Development certificate, or `CODESIGN_IDENTITY`) so the Keychain's **Always Allow**
answer survives rebuilds instead of prompting after every one. Extra arguments go to the app, e.g.
`scripts/dev-run.sh -kinhin.autoStartFleet NO` overrides the auto-start preference for that run only.

From the repo root, `swift package --disable-sandbox dev` does the same (the sandbox must be off because it signs and
launches the app); arguments pass through, e.g. `swift package --disable-sandbox dev --env-tokens`.
To skip the Keychain entirely in a debug build, run `scripts/dev-run.sh --env-tokens`: forge tokens are then read
from environment variables (`KINHIN_TOKEN_GITHUB`, `KINHIN_TOKEN_GITEA`, …, and `KINHIN_TOKEN_<ACCOUNT>` for named
accounts, upper-cased with non-alphanumerics as `_`), loaded from a git-ignored `.env.dev` (copy
`.env.dev.example`). The same works for the CLI: `KINHIN_TOKEN_STORE=env KINHIN_TOKEN_GITHUB=… swift run kinhin
auth status`. Tokens typed into the app in this mode last for that run only. It exists only in debug builds —
release builds always use the Keychain.

## Support kinhin

kinhin is free and built by one developer, with no ads and no telemetry. If it saves you time, you can
[sponsor on GitHub](https://github.com/sponsors/RabinApps), [donate via PayPal](https://www.paypal.com/donate/?hosted_button_id=YEJ37WF4Q3HPC),
or [buy me a coffee](https://buymeacoffee.com/rabinapps). Companies can become sponsors and get a logo here and on
the website: see [Support & sponsors](docs/support.md) or email support@rabinapps.com. Using kinhin in your project? [Add it to the list](docs/used-by.md).

**More from Rabin Apps:** [SupDesk](https://supdesk.app/en), the feedback and support console for solo founders, devs and small teams.

## License

Copyright © 2026 Rabin Apps, LLC. Licensed under the [Apache License 2.0](LICENSE).

kinhin bundles no third-party code at runtime; it shells out to [Tart](https://tart.run) and links [Yams](https://github.com/jpsim/Yams) (both Apache-2.0). See [NOTICE](NOTICE) for attribution details.
