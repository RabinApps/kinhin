<p align="center"><img src="assets/brand/AppIcon.iconset/icon_128x128@2x.png" alt="kinhin" width="96"></p>

# kinhin ○

**Commit it. Screenshot it. Ship it.** Your Mac is your CI. Your repo is your video studio, and your screenshot studio.

Ephemeral, autoscaling runners for GitHub Actions, Gitea and Forgejo Actions and GitLab CI/CD, plus narrated launch videos
built from a file in your repo.

**[kinhin.dev](https://kinhin.dev)** · [Quick start](https://kinhin.dev/guide/quick-start) ·
[Introducing the beta](https://kinhin.dev/blog/introducing-kinhin-beta)

> **Beta (`v0.0.1-beta-1`).** Supported: **GitHub, Gitea, Forgejo and GitLab CE**. Gitea, Forgejo and GitLab CE are
> tested on every runtime (Tart macOS and Linux VMs, Apple container, Docker, host mode); GitHub on Tart macOS VMs and
> Apple container. Buildkite, Azure Pipelines and Bitbucket Pipelines are planned for a later release. Please [report what you find](https://github.com/RabinApps/kinhin/issues/new/choose); see
> [what has been tested](docs/forges.md#what-has-been-tested) and the [roadmap to v0.1.0](docs/beta-roadmap.md).
> kinhin sends no telemetry. [Support kinhin](docs/support.md).

> ○ kinhin (kin-hin) is walking meditation: slow, deliberate steps between sittings.
> Here, one step at a time: a queued job arrives, a runner is born, serves, and is released.

kinhin does two things, both calmly and on hardware you already own:

- **CI that scales to your queue.** Self-hosted runners that appear for one job and are gone when it ends: the mindful CI.
- **Store screenshots in every locale.** `kinhin mobile init` adds a fastlane `screenshots` lane (snapshot for iOS, screengrab for
  Android) for iOS, Android, Flutter, React Native and Kotlin Multiplatform. The screenshots are CI artifacts, and they can feed the
  launch video.
- **Videos that rebuild with your release.** `kinhin video build` turns a config in your repo into a narrated launch video:
  your words, a voice, themes, captions and music, built in a container, on the fleet if you like
  ([below](#your-repo-is-your-video-studio)).

## The CI

kinhin runs [Tart](https://tart.run) macOS virtual machines on your Apple Silicon Mac — plus Linux jobs in
[apple/container](https://github.com/apple/container) microVMs, Docker containers, or Tart Linux VMs — and turns them
into ephemeral self-hosted CI runners. It watches your queues and grows or shrinks the fleet to match: a fresh VM (or
container) boots for each job, runs it, and is deleted. Host CPU, memory, and disk headroom are always reserved, so your
Mac stays usable. For fully trusted repos an opt-in [host mode](docs/runtimes.md#host-mode-run-jobs-directly-on-your-mac)
runs jobs directly on the Mac, with no isolation.

- **Ephemeral by default** — every job gets a fresh VM or container; no state leaks between jobs.
- **Multi-forge, multi-runtime** — four forges and four runtimes in one fleet, routed per repo, workflow, or `runs-on:`
  label ([Forges](docs/forges.md), [Runtimes & routing](docs/runtimes.md)).
- **Fast, dense, resource-aware** — linked clones boot in seconds, an opt-in [warm pool](docs/scaling.md#warm-pool)
  (`warm_pool`) keeps booted VMs waiting so jobs skip the boot, `runners_per_vm` packs small jobs onto one VM, and the
  scaler never exceeds what your Mac can handle (`kinhin doctor`). Why: [Why kinhin](docs/why.md).
- **Toolchains your way** — bake, pin per repo, or install per job ([Toolchains](docs/toolchains.md)).
- **App, menu bar, or headless daemon** — same engine, same config ([The app](docs/app.md)).

## Requirements

- Apple Silicon Mac, macOS 15+, ~60 GB free disk ([sizing](docs/hardware.md)), and an access token for a
  [forge](docs/forges.md) (e.g. a GitHub PAT with `repo` scope)
- Tart for macOS jobs (kinhin installs it, see below). Linux jobs are optional: apple/container (recommended; `kinhin setup repair container`), Docker, or a Tart Linux VM ([install](docs/install.md#installing-a-linux-runtime), [runtimes](docs/runtimes.md#choosing-a-linux-runtime))

## Install

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

The script verifies the signed, notarized DMG, installs **kinhin.app**, and links the `kinhin` CLI. Pinned versions,
air-gapped installs, uninstall and update checks: [Install](docs/install.md). Tart is installed by
`kinhin setup repair tart` (or the app's setup window); manual brew commands live in
[Installing Tart](docs/install.md#installing-tart).

Setting up with an AI agent? Give it the kinhin skills first, then let it do the rest
([how](https://kinhin.dev/guide/quick-start#set-up-your-first-fleet)):

```bash
npx skills add RabinApps/kinhin --skill '*' --global
```

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

## Your repo is your video studio

Launch videos go stale the day after you ship. Here the video is a file: edit it, review it, rebuild it.

```bash
kinhin video init launch                 # a starter config in .kinhin/videos/launch.yml
kinhin video music search "calm piano"   # free, openly licensed (CC0) music; `add 1` downloads it into the repo
kinhin video build launch                # builds .kinhin/videos/out/launch/launch.mp4 in a container (Apple container or Docker)
```

- **From a config, not an editor.** Scenes, narration, themes (your fonts and colors), captions and music are YAML in
  `.kinhin/videos/`. The same file builds 16:9 and vertical cuts.
- **Your product on screen.** Recordings of your app, browser or terminal play in a drawn laptop or window frame; the checker
  fails a build whose video is silent, too quiet, black or off size.
- **Reproducible.** The pipeline (Motion Canvas, Chromium, ffmpeg and the open Kokoro voice) is baked into a published
  container image, so a build needs no setup beyond a container runtime. Your sources never leave the Mac.
- **Free to use.** No watermark, no account, no telemetry. Music search covers CC0 and public-domain tracks by default.
- **On the fleet, or opt-in in CI.** `--on-fleet` builds on a kinhin runner; a [GitHub workflow](docs/ci-video.md) can rebuild
  your videos on a release. See the [video gallery](docs/video-gallery.md) for what it makes.

Start here: [Add videos to your project](docs/videos-for-your-project.md).

## Documentation

[Why](docs/why.md) · [Install](docs/install.md) · [Security](docs/security.md) · [App](docs/app.md) ·
[Hardware](docs/hardware.md) · [Scaling](docs/scaling.md) · [Requeue/skip](docs/requeue-skip.md) ·
[Toolchains](docs/toolchains.md) · [Forges](docs/forges.md) ([API](docs/forges/README.md)) · [Runtimes](docs/runtimes.md) ·
[Workflow testing](docs/workflow-testing.md) · [Product videos](docs/videos-for-your-project.md) · [Agents & MCP](docs/agents.md) · [Architecture](docs/architecture.md) ·
[Troubleshooting](website/guide/troubleshooting.md) · [Roadmap](docs/beta-roadmap.md)

## Commands

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

## Contributing and support

`swift build` and `swift test` need no VMs or network; conventions, the debug-app workflow and `scripts/check.sh` are in
[CONTRIBUTING.md](CONTRIBUTING.md). kinhin is free, with no ads and no telemetry; [support it](docs/support.md) or
[add your project to the list](docs/used-by.md). More from Rabin Apps: [SupDesk](https://supdesk.app/en).

## License

Copyright © 2026 Rabin Apps, LLC. Licensed under the [Apache License 2.0](LICENSE).
kinhin shells out to [Tart](https://tart.run) and links [Yams](https://github.com/jpsim/Yams) (both Apache-2.0); see [NOTICE](NOTICE).
