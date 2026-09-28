# kinhin ○

**The mindful CI — autoscaling runners that live on your Mac: GitHub Actions, Gitea/Forgejo Actions, and GitLab CI/CD.**

> ○ kinhin (kin-hin) is walking meditation: slow, deliberate steps between sittings.
> Here, one step at a time: a queued job arrives, a runner is born, serves, and is released.

kinhin runs [Tart](https://tart.run) macOS virtual machines on your Apple Silicon Mac — plus
Linux jobs in [apple/container](https://github.com/apple/container) microVMs or in Docker
containers — and turns them into ephemeral self-hosted CI runners. It watches your repositories'
queued jobs and grows or shrinks the fleet to match — a fresh VM (or container) boots for each
job, runs it, and is deleted. For repos you fully trust, an opt-in **host** mode runs jobs directly
on your Mac instead — no VM, no isolation (see [Host mode](docs/runtimes.md#host-mode-run-jobs-directly-on-your-mac)).
Your Mac stays usable: host CPU, memory, and disk headroom are always reserved.

```
┌─────────────────────────── your Mac ───────────────────────────┐
│  menu bar ○  ── FleetEngine ── poll forges (queued jobs)         │
│                     │        GitHub · Gitea · GitLab            │
│   routes each job: repo/workflow → Tart VM, container, or host  │
│     ┌───────────────┬───────────────┬─────────────────┐         │
│   tart VM #1    tart VM #2    🐧 container #1 … (up to cap)     │
│   macOS jobs    macOS jobs    Linux jobs    runners_per_vm/VM   │
└─────────────────────────────────────────────────────────────────┘
```

- **Ephemeral by default** — every job gets a freshly cloned VM; the runner deregisters itself
  afterwards and the VM is deleted. No state leaks between jobs.
- **Multi-forge** — GitHub Actions, Gitea Actions, Forgejo, and GitLab CI/CD from the same pool; the Forge
  abstraction keeps the door open for other platforms (see [Forge support](docs/forges.md)).
- **Multi-runtime** — macOS jobs run in Tart VMs, Linux jobs in [apple/container](https://github.com/apple/container)
  microVMs or Docker containers, from one fleet: each job is routed by repo, workflow, or `runs-on:` label, and the host
  budget is partitioned across the pools so neither can overcommit your Mac (see
  [Runtimes & routing](docs/runtimes.md)). Trusted repos can opt in to
  [host mode](docs/runtimes.md#host-mode-run-jobs-directly-on-your-mac): jobs run directly on your Mac, unisolated.
- **Many jobs per VM** — `runners_per_vm` registers several runner processes on one Tart VM, so
  small jobs share a VM instead of each paying a full boot.
- **Fast** — VMs are linked clones of one prepared base image, so boots take seconds, not minutes.
- **Resource-aware** — the scaler never exceeds what your Mac can handle (see `kinhin doctor`).
- **Toolchains your way** — bake them into the image, let kinhin install and pin them, or install
  per job, with a shared download cache (see [Toolchains](docs/toolchains.md)).
- **App, menu bar, or headless** — a main window, a classic tray app, or a LaunchAgent daemon;
  same engine, same config (see [The kinhin app](docs/app.md)).
- **One-line install** — `curl … | bash` from GitHub Releases, with daily update checks; a
  Homebrew tap is optional.

## Requirements

- Apple Silicon Mac (arm64), macOS 14+
- [Tart](https://tart.run):
  ```bash
  brew tap openai/tools
  brew trust openai/tools
  brew install openai/tools/tart
  ```
- A GitHub PAT with `repo` scope for the repository you want to serve (or a Gitea/Forgejo or
  GitLab access token if you only use those — see [Forge support](docs/forges.md))
- Optional — Linux jobs in [apple/container](https://github.com/apple/container):
  `brew install container && container system start` (macOS jobs always need Tart)
- ~60 GB free disk for the base image plus per-VM scratch

## Install

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

The script sha256-verifies the release DMG, copies **kinhin.app** to /Applications, and symlinks
the `kinhin` CLI into /usr/local/bin. Releases are Developer ID signed and notarized. Remove
everything with `bash scripts/install.sh --uninstall` (config and your Keychain PAT are kept).
Pinned versions, air-gapped installs, update checks, and Homebrew are covered in
[docs/install.md](docs/install.md).

## Quick start (CLI)

```bash
# 1. Install tart (skipped automatically if tart is already on your PATH)
brew tap openai/tools
brew trust openai/tools
brew install openai/tools/tart

# 2. Create a starter config
kinhin config init
#    edit ~/Library/Application Support/kinhin/config.yaml
#    -> set repo: "your-org/your-repo" and the labels jobs will request

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

`~/Library/Application Support/kinhin/config.yaml` — full template via `kinhin config init`.
Key fields:

| Field                                      | Meaning                                                                                                                                                                          |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `repo`                                     | GitHub scope to serve: `owner/name` for one repo, or a bare org name for org-level runners that serve **every repo in the organization** (PAT needs org runner-admin permission) |
| `labels`                                   | Jobs must request _all_ of these to be picked up                                                                                                                                 |
| `min_runners` / `max_runners`              | Scaling bounds (in VMs)                                                                                                                                                          |
| `runners_per_vm`                           | Runner processes per VM — many-to-one job density (1–8; 1 = one job per VM, most isolated)                                                                                       |
| `poll_interval`                            | Seconds between GitHub polls (≥ 5)                                                                                                                                               |
| `vm.cpu` / `vm.memory_gb` / `vm.ephemeral` | Per-VM shape                                                                                                                                                                     |
| `image`                                    | Tart image cloned per runner (`tahoe-base` after prepare)                                                                                                                        |
| `provision_script`                         | Host script baked into the image by `image prepare` (your toolchains; see [Baking toolchains](docs/toolchains.md#baking-toolchains-into-the-base-image))                         |
| `reserve.cpu` / `reserve.memory_gb`        | Host headroom kept free                                                                                                                                                          |
| `reserve.disk_gb`                          | Host disk (GB) kept free (default 10)                                                                                                                                            |

The effective concurrency cap is the smallest of `max_runners` and what your Mac's CPU, memory,
and disk can hold after the `reserve` headroom; `kinhin doctor` prints the cap and the binding
constraint. See [How scaling works](docs/scaling.md) for the formula and the scaling loop.

## Commands

```
kinhin config init          Write the starter config
kinhin auth set|status|clear   (set/replace PAT; a running daemon picks it up live)
kinhin auth add|list|remove    Manage additional GitHub/Gitea accounts (auth set --account NAME stores one's token)
kinhin auth status --json    All forges' stored-token state in one machine-readable document (exit 1 until ready)
kinhin doctor [--json]      Prerequisites + computed capacity (--json: host, runtime health, stored tokens, checklist,
                             and capacity in one machine-readable document; ready=false until every half passes)
kinhin setup-status [--json] First-run checklist; exit 1 until ready (--json for scripts)
kinhin runtimes [--json]    Pools, capacity, budget split, live health, and routes (--no-health skips probes)
kinhin runtimes route add <pattern> <tart|appleContainer|docker|host> [--consent]
                             Route a repo (`owner/repo`) or workflow (`owner/repo@Name`) — same validated
                             editor as the Runtimes pane; a running daemon reloads routing live.
                             `host` runs jobs unisolated on this Mac and requires --consent
kinhin runtimes route remove <pattern>
                             Delete that route (e.g. `acme/api` or `acme/web@Nightly`)
kinhin setup repair host-agent
                             Install the GitHub + Gitea runner agents used by host routes (one time)
kinhin image prepare        Build the runner base image (once); --provision-script <file>
                             bakes your toolchains in (see docs/toolchains.md); `toolchains:`
                             config entries are baked automatically and downloads
                             go through a shared host cache (auto-pruned)
kinhin image prepare --toolchain <spec> [--stack <name>]
                             Override the config's toolchains for this prepare
kinhin toolchains           Managed-toolchain catalog, selections, shared-cache state
kinhin toolchains prune [--dry-run]
                             Expire stale host-cache entries now
kinhin toolchains helper [--linux]
                             Print the per-job `kinhin-toolchain` helper baked into images
kinhin start                Run the fleet in the foreground
kinhin daemon               Run the daemon in the foreground
kinhin daemon install       Install + start the LaunchAgent
kinhin daemon uninstall     Remove the LaunchAgent
kinhin status|watch         Fleet status
kinhin pause|resume         Hold the fleet / resume scaling
kinhin stop                 Stop the fleet
kinhin logs [-n N]          Recent log lines
```

## Documentation

| Doc                                                              | Covers                                                                      |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------- |
| [Install](docs/install.md)                                       | Install script, air-gapped installs, update checks, Homebrew tap            |
| [The kinhin app](docs/app.md)                                    | Main window tabs, launch modes, Siri & Shortcuts, app + daemon together     |
| [How scaling works](docs/scaling.md)                             | Capacity cap, the scaling loop, `runners_per_vm`, recovery                  |
| [Toolchains & the shared cache](docs/toolchains.md)              | Provision scripts, managed toolchains, per-job installs, the download cache |
| [Forge support](docs/forges.md)                                  | GitHub, Gitea, Forgejo, GitLab, multiple accounts, future forges            |
| [Runtimes & routing](docs/runtimes.md)                           | Tart, Apple `container`, Docker, host mode, per-repo/per-workflow routing   |
| [Architecture](docs/architecture.md)                             | Package targets, source layout, tests, CI                                   |
| [Runtime abstraction design](docs/runtime-abstraction-design.md) | Design document for the Runtime layer                                       |

## Troubleshooting

- **`kinhin doctor` shows "tart: NOT FOUND"** — install tart with `brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart`, then reopen
- **"tart: INSTALLED BUT KILLED ON LAUNCH ✗"** — the OpenAI-tap bottle is un-notarized (openai/homebrew-tools#27); Gatekeeper kills it before it runs. Roll back to the notarized Cirrus Labs build — `kinhin doctor` and the setup app print/offer the exact commands:
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
  `~/Library/Application Support/kinhin/logs/kinhin.log`.
- **Token rejected** — re-run `kinhin auth set`; the PAT needs `repo` scope and access to the repo.
- **First launch blocked** — only applies to old releases or locally built copies (official
  releases are signed and notarized). Right-click → Open, or `xattr -cr /Applications/kinhin.app`.

## Contributing

`swift build` and `swift test` need no VMs or network. Conventions (layout, style, error handling,
formatting) are in [CLAUDE.md](CLAUDE.md); the package layout is in
[docs/architecture.md](docs/architecture.md).

## License

Copyright © 2026 Rabin Apps, LLC. Licensed under the [Apache License 2.0](LICENSE).

kinhin bundles no third-party code at runtime; it shells out to [Tart](https://tart.run) and links [Yams](https://github.com/jpsim/Yams) (both Apache-2.0). See [NOTICE](NOTICE) for attribution details.
