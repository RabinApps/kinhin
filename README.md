# Orchard 🌳

**Autoscaling CI runners that live on your Mac — GitHub Actions and Gitea Actions.**

Orchard runs [Tart](https://tart.run) macOS virtual machines on your Apple Silicon Mac and turns
them into ephemeral self-hosted CI runners. It watches your repositories' queued jobs
and grows or shrinks the fleet to match — a fresh VM boots for each job, runs it, and is deleted.
Your Mac stays usable: host CPU, memory, and disk headroom are always reserved.

```
┌─────────────────────────── your Mac ───────────────────────────┐
│  menu bar 🌳 ── FleetEngine ── poll forges (queued jobs)         │
│                     │                 GitHub · Gitea            │
│     routes each job: repo/workflow → Tart VM or container       │
│     ┌───────────────┬───────────────┬─────────────────┐         │
│   tart VM #1    tart VM #2    🐧 container #1 … (up to cap)     │
│   macOS jobs    macOS jobs    Linux jobs    runners_per_vm/VM   │
└─────────────────────────────────────────────────────────────────┘
```

- **Ephemeral by default** — every job gets a freshly cloned VM; the runner deregisters itself
  afterwards and the VM is deleted. No state leaks between jobs.
- **Multi-forge** — GitHub Actions today, Gitea Actions alongside it from the same pool;
  the Forge abstraction keeps the door open for other platforms (see below).
- **Multi-runtime** — macOS jobs run in Tart VMs, Linux jobs in [apple/container](https://github.com/apple/container)
  microVMs, from one fleet: each job is routed by repo, workflow, or `runs-on:` label, and the host
  budget is partitioned across the pools so neither can overcommit your Mac (see
  [Per-repo & per-workflow runtime routing](#per-repo--per-workflow-runtime-routing)).
- **Many jobs per VM** — `runners_per_vm` registers several runner processes on one Tart VM, so
  small jobs share a VM instead of each paying a full boot.
- **Fast** — VMs are linked clones of one prepared base image, so boots take seconds, not minutes.
- **Resource-aware** — the scaler never exceeds what your Mac can handle (see `orchard doctor`).
- **Menu bar app or headless daemon** — same engine, same config, your choice.
- **One-line install** — `curl … | bash` from GitHub Releases; a Homebrew tap is optional.
- **Update checks** — the menu bar app checks GitHub Releases daily and can download the new DMG for you.
  `

## Requirements

- Apple Silicon Mac (arm64), macOS 13+
- [Tart](https://tart.run):
  ```bash
  brew tap openai/tools
  brew trust openai/tools
  brew install openai/tools/tart
  ```
- A GitHub PAT with `repo` scope for the repository you want to serve (or a Gitea access token
  if you only use Gitea — see [Forge support](#forge-support-github-gitea--the-future))
- Optional — Linux jobs in [apple/container](https://github.com/apple/container):
  `brew install --cask container && container system start` (macOS jobs always need Tart)
- ~60 GB free disk for the base image plus per-VM scratch

## Quick start (CLI)

```bash
# 1. Install tart (skipped automatically if tart is already on your PATH)
brew tap openai/tools
brew trust openai/tools
brew install openai/tools/tart

# 2. Create a starter config
orchard config init
#    edit ~/Library/Application Support/Orchard/config.yaml
#    -> set repo: "your-org/your-repo" and the labels jobs will request

# 3. Store a GitHub PAT (repo scope) — it goes in your Keychain, not a file
orchard auth set

# 4. Check prerequisites and see how many VMs your Mac can host
orchard doctor

# 5. Prepare the runner base image (once; downloads + provisions a VM, takes a while)
orchard image prepare

#    Manual equivalent of what `image prepare` automates:
#      tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest tahoe-base
#      tart run tahoe-base
#    (then the runner agent is injected over SSH; `orchard image prepare` does all of it,
#     including checking whether tart/the image already exist before downloading)

# 6. Point your config at the prepared image
#    image: "tahoe-base"

# 7. Go
orchard start          # foreground, Ctrl-C to stop
# or
orchard daemon install # headless LaunchAgent, survives reboots
```

Dispatch a workflow whose job matches your labels:

```yaml
jobs:
  build:
    runs-on: [self-hosted, macos, arm64] # must include all configured labels
    steps:
      - run: uname -m # arm64 — you're running on your own Mac
```

Watch the fleet: `orchard watch` (live) or `orchard status` (one shot).

## Install (one line)

Latest release:

```bash
curl -fsSL https://github.com/OWNER/orchard/releases/latest/download/install.sh | bash
```

Pinned version, or from a local DMG (air-gapped machines):

```bash
curl -fsSL .../install.sh | bash -s -- v0.1.0
bash scripts/install.sh /path/to/Orchard-0.1.0-arm64.dmg
```

The script sha256-verifies the DMG against the release `checksums.txt`, copies **Orchard.app** to
/Applications, and symlinks the `orchard` CLI into /usr/local/bin. Downloads made with `curl` carry
no quarantine attribute, so the app launches with **no Gatekeeper prompts and no notarization** —
the Open-Anyway dance only applies to browser-downloaded DMGs, and the script clears that case too.
Remove everything with `bash scripts/install.sh --uninstall` (config and your Keychain PAT are kept).

After installing, the menu bar app checks GitHub Releases at most once a day and shows an
**Update available — Orchard x.y.z…** item when a newer `v*` release exists; clicking it downloads
the DMG (via URLSession, so it is never quarantined) and opens it for a one-click install. Point it
at your fork with `ORCHARD_UPDATE_REPO=owner/orchard` if needed.

## Quick start (menu bar app)

Install with the one-liner above, then launch **Orchard** from Applications. The setup window walks
through the same steps as the CLI — installing tart, creating the config, storing the token, and
preparing the image — then starts the fleet. The tree in your menu bar shows the number of live
runner VMs. (Prefer dragging? The DMG from Releases still works.)

> **Unsigned app note:** the app is not notarized. On first launch, right-click → **Open**, or run
> `xattr -cr /Applications/Orchard.app`. (Homebrew's cask verifies the sha256, so `brew install
--cask orchard` is the smoothest path.)

## Configuration

`~/Library/Application Support/Orchard/config.yaml` — full template via `orchard config init`.
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
| `provision_script`                         | Host script baked into the image by `image prepare` (your toolchains; see [Baking toolchains](#baking-toolchains-into-the-base-image))                                           |
| `reserve.cpu` / `reserve.memory_gb`        | Host headroom kept free                                                                                                                                                          |

The effective concurrency cap is
`min(max_runners, (cores − reserve.cpu) / vm.cpu, (RAM − reserve.memory_gb) / vm.memory_gb)` —
`orchard doctor` prints the result and the binding constraint.

## Baking toolchains into the base image

GitHub-hosted runners ship with Xcode, JDKs, Go, Rust, and dozens of other tools preinstalled.
Orchard's runner VMs contain exactly what the base image contains — each job gets a fresh
linked clone of it, so anything a job installs is thrown away when the VM is deleted. The
place to add your own toolchains is `orchard image prepare`: it can run **your provision
script** inside the VM once, after the runner agents are installed, and every runner VM then
boots with whatever it installed.

Write a script — it runs verbatim as the `admin` user, and a failure aborts the prepare with
the previous image left intact:

```bash
#!/bin/bash
# ~/orchard/provision.sh — baked into the image by `orchard image prepare`
brew install wget cmake
mise install go@1.23.4 rust@1.82 java@temurin-21   # exact versions; mise ships in the base image
go version && rustc --version && java -version      # their output is logged as the audit trail
```

Wire it up either way (the CLI flag wins over the config key):

```bash
orchard image prepare --provision-script ~/orchard/provision.sh
```

```yaml
# config.yaml
provision_script: "~/orchard/provision.sh"
```

- **Versioning is yours.** The script is the pin: every prepare rebuilds from the pristine
  upstream image, so editing the script and re-running prepare is how toolchains change —
  there is no drift between builds. The base image ships **Homebrew** and **mise**, so either
  `mise install go@1.23.4` (exact patches) or versioned formulas like `brew install go@1.23
  temurin@21` (pinned major/minor) work.
- **Audit trail.** End the script with `go version && java -version …` — Orchard logs the
  stdout tail during prepare, recording what went into that image build (see `orchard logs`).
- **Checklist guard.** A configured script that is missing or empty fails the first-run
  checklist (`orchard setup-status` / the setup window) with a one-click fix, so the typo is
  caught before a 20-minute prepare downloads gigabytes and then aborts.
- **Timeout.** The script gets its own 30-minute budget, separate from the agent install.
- **Full Xcode?** Don't install it from a script (it's tens of GB) — point `image:` (or
  `image prepare --source`) at Cirrus Labs' `macos-tahoe-xcode:16` or `macos-runner:tahoe`
  images instead: Xcode (and Flutter) preinstalled, with `xcodes` to switch versions.
- **Small tools only?** Per-job `actions/setup-go`, `actions/setup-java`,
  `dtolnay/rust-toolchain`, and friends still work on Orchard runners and need no image
  work — at the cost of re-downloading the toolchain in every job.

## Commands

```
orchard config init          Write the starter config
orchard auth set|status|clear   (set/replace PAT; a running daemon picks it up live)
orchard auth status --json    All forges' stored-token state in one machine-readable document (exit 1 until ready)
orchard doctor [--json]      Prerequisites + computed capacity (--json: host, runtime health, stored tokens, checklist,
                             and capacity in one machine-readable document; ready=false until every half passes)
orchard setup-status [--json] First-run checklist; exit 1 until ready (--json for scripts)
orchard runtimes [--json]    Pools, capacity, budget split, live health, and routes (--no-health skips probes)
orchard runtimes route add <pattern> <tart|appleContainer>
                             Route a repo (`owner/repo`) or workflow (`owner/repo@Name`) — same validated
                             editor as the Runtimes pane; a running daemon reloads routing live
orchard runtimes route remove <pattern>
                             Delete that route (e.g. `acme/api` or `acme/web@Nightly`)
orchard image prepare        Build the runner base image (once); --provision-script <file>
                             bakes your toolchains in (see below)
orchard start                Run the fleet in the foreground
orchard daemon               Run the daemon in the foreground
orchard daemon install       Install + start the LaunchAgent
orchard daemon uninstall     Remove the LaunchAgent
orchard status|watch         Fleet status
orchard pause|resume         Hold the fleet / resume scaling
orchard stop                 Stop the fleet
orchard logs [-n N]          Recent log lines
```

## How scaling works

Every `poll_interval` seconds the engine:

1. Cleans up any failed instances from the previous pass.
2. Asks each forge for queued jobs on its scope and filters them by `labels`.
3. **Routes** each job to a runtime — workflow route → repo route → `runs-on:` label → default —
   and buckets the demand per pool.
4. Computes the desired instance count **per pool**:
   `desired = clamp(ceil(pool_queue / runners_per_vm), min_runners, pool_cap)`, where `pool_cap`
   is that runtime's slice of the host budget (`budget` weights) when multiple runtimes are
   configured, or the full `min(max_runners, (cores − reserve.cpu) / vm.cpu, (RAM −
reserve.memory_gb) / vm.memory_gb)` for a single-pool fleet.
5. Spawns instances up to `desired` (linked clone → boot → SSH → register `runners_per_vm`
   runners → `run.sh`) — Tart VMs for macOS pools, apple containers for Linux pools.
6. Deletes idle instances when `desired` drops (scale to zero by default).

`runners_per_vm` is the density knob: with the default `1`, each job gets its own VM (most
isolation); with `4`, one VM serves four concurrent jobs before the scaler spawns another. Small
jobs on identical macOS stacks are the sweet spot — set it high enough that `vm.cpu`/`vm.memory_gb`
cover the _sum_ of the jobs you expect on one VM.

Ephemeral runners register with `--ephemeral`, so GitHub removes the runner registration as soon
as the job finishes; Orchard then deletes the VM. If the engine crashes or restarts it reconciles
`tart list` against its persisted state, adopts orphaned VMs, and drops records whose VMs vanished.

Registration tokens are short-lived (1 h); Orchard caches and refreshes them automatically. Your
PAT lives in the login Keychain.

Config edits made from the **Runtimes…** pane (routes, budget split, labels) reach a running fleet
live via `reload_config` — no restart; a running fleet simply re-buckets demand on its next poll.

## Headless + menu bar together

The menu bar app runs the engine in-process when no daemon is active, and attaches read/write to
the daemon's unix socket when `orchard daemon install` has been used. Either way there is exactly
one fleet.

## Optional: Homebrew distribution

A personal tap is _not_ required — the one-line install above is the intended path. If you prefer
`brew` on your machines, this repo ships tap templates in `packaging/homebrew-tap/`:

1. Create a repo named `homebrew-tap` under your account.
2. Copy `Casks/orchard.rb` and `Formula/orchard.rb` into it, replacing `RabinApps`
   with your GitHub handle.
3. After each release (tag a `v*` and CI publishes the DMG, CLI zip, and `checksums.txt` to
   Releases), update the version and the sha256 values in your tap from that `checksums.txt`.
4. Users install with:

```bash
brew tap RabinApps/tap
brew install --cask orchard    # menu bar app
brew install orchard           # CLI
```

## Troubleshooting

- **`orchard doctor` shows "tart: NOT FOUND"** — install tart with `brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart`, then reopen
- **"tart: INSTALLED BUT KILLED ON LAUNCH ✗"** — the OpenAI-tap bottle is un-notarized (openai/homebrew-tools#27); Gatekeeper kills it before it runs. Roll back to the notarized Cirrus Labs build — `orchard doctor` and the setup app print/offer the exact commands:
  ```bash
  brew uninstall openai/tools/tart openai/tools/softnet
  brew tap cirruslabs/cli
  brew trust cirruslabs/cli
  brew install cirruslabs/cli/tart
  ```
  Re-run `orchard doctor` afterwards; it will offer to move back to the OpenAI tap once a fixed bottle ships.
  the app or restart the daemon so it picks up your PATH.
- **Jobs queue but no VMs start** — check that the job's `runs-on:` contains _every_ label in your
  config; the scaler only counts jobs it could actually run.
- **VM boots but the runner never registers** — the base image may predate the injected agent.
  Re-run `orchard image prepare`. Full logs: `orchard logs -n 200` or
  `~/Library/Application Support/Orchard/logs/orchard.log`.
- **First launch blocked** — only happens with a browser-downloaded DMG (curl-fetched or
  script-installed copies are never quarantined). Right-click → Open, or
  `xattr -cr /Applications/Orchard.app`.
- **Token rejected** — re-run `orchard auth set`; the PAT needs `repo` scope and access to the repo.

## Architecture

Single Swift package:

| Target        | Role                                                                       |
| ------------- | -------------------------------------------------------------------------- |
| `OrchardKit`  | Engine: GitHub client, Tart wrapper, SSH executor, autoscaler, RPC, daemon |
| `orchard`     | CLI                                                                        |
| `orchard-app` | Menu bar app (AppKit)                                                      |

Inside the targets, code is organized by domain:

| Location                        | Contents                                                                                                     |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `OrchardKit/Core/`              | Shell, logging, paths, keychain, RPC, mutex/box primitives                                                   |
| `OrchardKit/Config/`            | YAML config, validation, template, capacity math, runtime routing                                            |
| `OrchardKit/Forges/`            | GitHub + Gitea forges, org-permission probe                                                                  |
| `OrchardKit/Runtimes/`          | Runtime protocol, Tart + Apple-container runtimes, routing pools                                             |
| `OrchardKit/Fleet/`             | FleetEngine (split: shell / reconcile / lifecycle), status model, records                                    |
| `OrchardKit/Images/`            | VM and container image preparation                                                                           |
| `OrchardKit/Setup/`             | Setup checklist, doctor probes (tart health, CLT)                                                            |
| `OrchardKit/Update/`            | GitHub-release update check                                                                                  |
| `orchard/OrchardCLI.swift`      | @main entry: arg parsing + dispatch only                                                                     |
| `orchard/Commands/`             | One file per command group (auth, doctor, image, run, runtimes, setup-status) + the CLICommand routing table |
| `orchard-app/AppMain.swift`     | @main entry: AppKit bootstrap, synchronous run loop                                                          |
| `orchard-app/AppDelegate.swift` | Lifecycle + engine wiring + refresh                                                                          |
| `orchard-app/UI/`               | Extensions: menu/status item, actions, token replacement, update flow, setup repairs, Runtimes pane          |

Tests: `swift test` (377 tests across three targets: the engine suite (OrchardKitTests — store, RPC, SSH, image pipeline, tart-health, CLT probe, org permissions, queue attribution (queued and running,
per repo), token replacement (Keychain upsert, live engine swap, daemon RPC), multi-forge (Gitea client, per-VM platform assignment, bootstrap, token-gated image provisioning), runtime
abstraction and routing (TartRuntime semantics, Apple-container runtime health/provision/exec/teardown, label pools, capacity partition, per-repo/per-workflow routing), config
ing (runtimes/budget/labels editors: section upsert, comment preservation, validation gating), hot-reload (engine applyReloaded, daemon reload_config RPC), update-check,
setup-checklist parity, and setup UI presentation/layout tested against fakes — no VMs required), plus OrchardCLITests (command routing table, starter-config
auto-create policy, flag parsing, status rendering, `config init` matrix, help text) and OrchardAppTests (menu construction, status title/line + VM-section
rendering, update menu states, update preferences, setup repair execution)).
CI: `.github/workflows/ci.yml` builds and tests on `macos-14`; `release.yml` publishes the DMG,
CLI zip, installer, and checksums to GitHub Releases on `v*` tags.

## Forge support (GitHub, Gitea, & the future)

Orchard is built on a **Forge abstraction**: the engine speaks one unified protocol — mint a registration token, list/delete runners, report queued demand, track running jobs — and each CI platform implements it behind that interface. Today two forges ship:

| Forge          | Status       | Runner agent                             | Scope shape                              |
| -------------- | ------------ | ---------------------------------------- | ---------------------------------------- |
| GitHub Actions | ✅ supported | actions-runner (GitHub's official agent) | `owner/name` repo or org                 |
| Gitea Actions  | ✅ supported | gitea-runner (formerly act_runner)       | `owner/name` repo or org on any instance |

One fleet can serve **both at the same time** from a shared VM pool: each VM is assigned at spawn to whichever forge has the most pending work, registers there, and is deleted when its job finishes. Token-gating ties platforms to credentials — an agent is baked into the image and a forge attaches only when that platform's token exists.

**Adding Gitea:** store a Gitea access token with runner-management rights on the scope, then declare the forge in `config.yaml`:

```yaml
gitea:
  instance: "https://gitea.example.com"
  scope: "owner/name" # or an org name
  labels: ["macos:host"] # jobs opt in via runs-on: macos:host
```

- Token: `orchard auth set --gitea` (or the checklist's Gitea token row). Both tokens live in the Keychain; replace either live without restarting.
- Image provisioning is **token-gated**: `orchard image prepare` bakes the GitHub agent only if a GitHub PAT is stored, and the gitea-runner binary only if a Gitea token is stored — no credential, no agent. Both runner versions are resolved from the vendors' release feeds at prepare time (pinned fallback when offline).
- Gitea VMs are ephemeral like GitHub's: gitea-runner has no `--ephemeral`, so Orchard watches for all of the VM's runners to go idle and deletes the VM after a short grace period.
- Demand polling uses the scope's task-queue endpoints; when the instance reports nothing usable, a `min_runners` floor keeps capacity available.

**More forges are planned.** The Forge protocol was designed so new platforms slot in without touching the engine: Forgejo (Gitea's upstream, wire-compatible with the Gitea forge), GitLab (its runner is Docker-executor-oriented, so a macOS host-mode path needs design work), Sourcehut, Buildkite, and others are all candidates. Adding one means implementing the Forge protocol (client + bootstrap script + lifecycle notes) — the autoscaler, VM pool, checklist, status surfaces, and tests all come for free. See `Sources/OrchardKit/Forge.swift` for the contract.

**Execution runtimes are the second axis** (design: [docs/runtime-abstraction-design.md](docs/runtime-abstraction-design.md)): every job is placed on a **Runtime** — a pluggable executor that provisions instances, runs the agent, and tears down. Two backends ship: **Tart** (macOS VMs) and **apple/container** (Linux microVMs); Docker and opt-in host-direct execution are candidates behind the same interface. The engine is runtime-agnostic — pools, capacity partitioning, and routing all live above the protocol, so new backends slot in without touching lifecycle code.

**Apple `container` is here for Linux jobs** — as an alternative to the planned Docker runtime, Orchard can run Linux jobs in [apple/container](https://github.com/apple/container) microVMs: one lightweight VM per runner container on Apple silicon, no Docker daemon, stronger isolation than a shared Docker VM. Add this to your config and run `orchard image prepare --container` to bake the agents into a Linux image:

```yaml
container:
  image: "orchard-ci-linux" # built by: orchard image prepare --container --target orchard-ci-linux
  cpus: 4
  memory_gb: 8
```

Requires the container CLI (`brew install --cask container && container system start`). macOS jobs still need Tart — containers run Linux workloads only. When `container:` is configured, the setup checklist and `orchard doctor` gain container rows (CLI health, system-service state, image present) with one-click fix actions; without it, the rows never appear. Run `orchard runtimes` (or the menu bar's **Runtimes…** pane) to see the pool, its cap, and its live health once configured.

### Per-repo & per-workflow runtime routing

One fleet can mix runtimes: macOS repos on Tart VMs, Linux repos in Apple containers. Add a `runtimes:` section to route per repo — and override per **workflow** (or per job) with labels:

```yaml
runtimes:
  default: tart # repos with no route
  budget: { tart: 0.6, appleContainer: 0.4 } # host-budget split (no overcommit by construction)
  routes:
    - pattern: "acme/ios-app" # whole repo → Tart VMs
      runtime: tart
    - pattern: "acme/api" # whole repo → Linux containers
      runtime: appleContainer
    - pattern: "acme/web@Nightly" # one workflow → containers
      runtime: appleContainer
```

Routing precedence: **workflow route → repo route → `runs-on:` label → default**. Container runners always register with an `orchard-container` label (plus optional `container.labels`), so any job can opt into the Linux pool with `runs-on: [orchard-container]` without touching Orchard's config. No route and no label → the `runtimes.default` pool. Capacity is partitioned by the `budget` weights — the tightest density that can still never overcommit your Mac — and `orchard status` reports `capacityByRuntime` so the split is visible. If a split starves a configured route (its runtime's cap hits 0), the pane warns you before you can save it.

In the menu bar app, **Runtimes…** opens a pane showing the pools with their per-runtime caps and budget shares, plus every route (repo and workflow). Each pool card carries a **live health chip** (● ready / ● missing / ● error) from the runtime's own probe — tart launch check, `container system status` — with the fix hint shown alongside any problem. The pane's **Budget** card edits the split directly: a slider per non-default runtime (the default keeps the remainder), a default-runtime picker, a **live cap preview** per row ("3 inst" updates as you drag), and a warning strip when the split on screen would starve a configured route with a cap of zero. The **Labels** card edits the fleet's base label set and `container.labels` (commit on Enter or focus loss; empty label lists are rejected, and the `orchard-container` routing marker is always merged in at pool build). Routes can be added and removed in place. Every change rewrites only the relevant section of `config.yaml` — comments elsewhere are preserved — and lands only if the updated file still passes the engine's full config validation; all of it reaches a running fleet live via `reload_config` (budget weights re-partition capacity, label edits rebuild the forges' demand query — no restart). Prefer the terminal? `orchard runtimes` prints the same pools/caps/budget/routes/health summary (see [Commands](#commands)).

## License

Copyright © 2026 Rabin Apps, LLC. Licensed under the [Apache License 2.0](LICENSE).

Orchard bundles no third-party code at runtime; it shells out to [Tart](https://tart.run) and links [Yams](https://github.com/jpsim/Yams) (both Apache-2.0). See [NOTICE](NOTICE) for attribution details.
