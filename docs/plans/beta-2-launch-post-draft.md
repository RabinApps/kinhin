---
title: Beta 2: hardening the supported forges
description: The second public beta of kinhin, the mindful CI for your Mac. What changed since beta 1, what has been tested for real, what has not, and where I need your help.
sidebar: false
aside: false
---

<!--
DRAFT for Friday, October 16, 2026. NOT for publishing as-is. Checklist: docs/plans/beta-2-launch-checklist.md. Gates T1 to T7
are defined there; G6 (the release and install command) carries over from beta 1. Each gate has a target block
(GATE:Tn start/end markers) and a fallback block (FALLBACK:Tn start/end markers). Keep exactly one, delete the other, markers
included. The post-publish items (G8 updater, nightly end-to-end run, G4 soak) are plain text and stay "not exercised yet",
"not running yet" and "Not done" until they happen. All [MEASURE: ...] placeholders and TODO(verify:...) comments must be
resolved or removed. Nothing here is true until its gate passed. website/blog/beta-2.md is a copy of this file: keep the two
identical until publish.
-->

# Beta 2: hardening the supported forges

_Friday, October 16, 2026 · Alex Rabin_

**kinhin** watches your CI queue and, for each queued job, starts a fresh VM or container on your Apple Silicon Mac,
registers a one-job runner, lets it run, then deletes it. Nothing idles and nothing is left over. It is free, open source
(Apache-2.0), and sends no telemetry. <!-- GATE:G6 start -->Today is the second public beta, `v0.0.1-beta-2`.<!-- GATE:G6 end --><!-- FALLBACK:G6 start -->The second public beta, `v0.0.1-beta-2`, is not released yet.<!-- FALLBACK:G6 end -->

It is still a beta, and the honest summary is short:

|                             | State today                                                                                                                                                                                                                |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Supported, run for real** | GitHub Actions, Gitea Actions, Forgejo Actions and GitLab CE. The runtime-by-runtime detail is in [What has been tested](#what-has-been-tested-and-what-has-not). |
| **Planned**                 | Buildkite, Azure Pipelines and Bitbucket Pipelines, in a later release.                                                                                                                                                    |
| **Hard limit**              | Apple allows two macOS guest VMs at once on a Mac, whatever the hardware. Linux containers are not capped by it.                                                                                                           |

If you only read one more section, read [Should you use it now?](#should-you-use-it-now). The rest is detail.

## Who I am

I'm Alex Rabin. I write code with AI agents, and I review and test what they produce. The story of why kinhin exists is in
the [beta 1 announcement](/blog/introducing-kinhin-beta#who-i-am-and-why-i-built-it), and it has not changed. [How this was
built](#how-this-was-built) says what that means for testing.

## What kinhin is

At its core, kinhin is an autoscaler for ephemeral CI runners that live on one Mac.

- **Runtimes.** macOS jobs run in [Tart](https://tart.run) VMs. Linux jobs can run in
  [apple/container](https://github.com/apple/container) microVMs, Docker containers, or Tart Linux VMs. Which runtime a
  job gets is routed per repo, per workflow, or by `runs-on:` label. An opt-in host mode runs jobs directly on the Mac
  with no isolation, behind an explicit consent flag.
- **Forges.** One pool can serve GitHub Actions, GitLab CI/CD, and Gitea and Forgejo Actions. Buildkite, Azure Pipelines
  and Bitbucket Pipelines are next. Adding another is documented step by step ([adding a forge](https://github.com/RabinApps/kinhin/blob/main/docs/adding-a-forge.md)).
- **Resource awareness.** The scaler works out how many instances your Mac can hold from its cores, memory and free disk,
  after reserving headroom. `kinhin doctor` shows the number ([scaling](/guide/scaling)).
- **Toolchains.** Bake tools into the image, pin them per repository, or install them per job, with an opt-in shared
  cache ([toolchains](/guide/toolchains)).
- **How you run it.** A menu bar app with a setup wizard, a full CLI, and a LaunchAgent daemon. Same engine, same config,
  one fleet. Tokens live in the macOS Keychain, not in the config file.

## What beta 2 is for

Beta 1 was about getting the four forges running at all. Beta 2 is about making them hold up on real projects, and about
the fleet around them. The [roadmap](/guide/beta-roadmap) lists four beta-2 goals: fixes from beta testers' real projects,
the GitHub lane of the end-to-end suite against a throwaway repository, the end-to-end suite running nightly on a dedicated
Mac, and the in-app updater exercised against a published release. The table in
[What has been tested](#what-has-been-tested-and-what-has-not) says where each one stands. The updater needs this release
published first, and the nightly run is not running yet.

## What changed since beta 1

These are the changes in the changelog's Unreleased section. Nothing here is outside it.

### The healing agent

A fleet breaks in dull ways: a warm VM gets deleted out of band, a toolchain cache fills the disk, an account gets detached,
the Apple container system stops. The healing agent fixes the four it can safely fix on its own. Anything destructive, such
as pruning images or reinstalling a runtime, it puts in a journal and waits for you.

- `kinhin heal` shows the journal. `kinhin heal approve ID` or `kinhin heal dismiss ID` acts on an entry.
- The app's Diagnostics sheet has a Healing card, and a notification fires when a fix succeeds.
- It is configured under `healing:`. [docs/healing.md](https://github.com/RabinApps/kinhin/blob/main/docs/healing.md)
  describes each rule.
- On macOS 26 with Apple Intelligence, the on-device model can pick from the allowed fixes for a problem no rule covers.

<!-- GATE:T3 start -->
I ran the four automatic cases live on my own Mac against the release commit. Each one was fixed, and the destructive actions
still waited for approval. The Apple Intelligence path was not part of those runs.
<!-- GATE:T3 end -->
<!-- FALLBACK:T3 start -->
The healing agent is unit-tested only. Its live scenarios are written but have not been run, and the Tart warm-VM lane in
particular has not run, so I am not claiming it works on a real fleet yet. Read [docs/healing.md](https://github.com/RabinApps/kinhin/blob/main/docs/healing.md)
before you let it act.
<!-- FALLBACK:T3 end -->

### Warm pools per image

A warm pool keeps booted, unregistered VMs ready, so the next job skips the clone and the boot. Until now the warm pool
covered only the top-level `image:`. Beta 2 adds `warm_pool` on an `images:` entry, so a job routed to a named image (for
example `xcode`) can get a ready VM too. The top-level `warm_pool` still covers `image:`, and the two share `max_runners`.
The app's "More images" card has a stepper for each image's pool, and the Capacity view shows the base image's.

A warm VM is a booted VM. It costs RAM and disk, and while it waits it holds a `max_runners` slot. Turning a pool off, or
removing an `images:` entry, recycles its VMs at once.

TODO(verify:T2): confirm whether the T2 run exercised `warm_pool` on an `images:` entry. If it did, say so in the table row
below; if not, keep the per-image row as unit-tested only.

### The video suite

`kinhin video` makes a narrated video of your own product from `.kinhin/videos/*.yml`, with no copy of the video suite in your
repository. It runs a published container image (Apple `container` or Docker) against your repository, and `--on-fleet`
builds on a runner through a generated GitHub workflow. Music, captions, themes and formats are config. `kinhin video music
search` finds CC0 and public-domain tracks, and `--license cc-by` also offers CC BY tracks and writes their credit line. Each
build lands in its own folder under `.kinhin/videos/out/`. The app's Fleet tab has a **Make a Video…** sheet that uses the same
code.

<!-- GATE:T7 start -->
The launch video for this project was built with the same suite and passed its checks (size, loudness, captions, poster and
GIF). It is on the home page.
<!-- GATE:T7 end -->
<!-- FALLBACK:T7 start -->
There is no launch video in this release. The video suite is, and its docs say how to make one.
<!-- FALLBACK:T7 end -->

### Mobile: fastlane, screenshots and CI files

`kinhin mobile init` scaffolds release setup for iOS, Android, Flutter, React Native, native projects, Capacitor and Ionic,
Kotlin Multiplatform and .NET MAUI: lanes, a pinned Gemfile, and a manual `mobile-release` workflow for `kinhin-xcode`. Expo
gets EAS config. It is opt-in, and nothing changes for a project that does not run it. A `screenshots` lane uses `snapshot`
for iOS UI tests and `screengrab` for Android instrumented tests, with optional device frames and upload.

`--ci` writes a pipeline for GitHub Actions, GitLab CI, Gitea and Forgejo Actions, Bitbucket Pipelines, Azure Pipelines or
Buildkite. Those files run your mobile release on that system. They do not make kinhin a runner for it: kinhin does not scale
runners for Buildkite, Azure Pipelines or Bitbucket Pipelines yet, which is beta-3 work.

The mobile and screenshot scaffolding is not one of this release's live gates. Treat the generated pipelines as untested on
your project until a run of your own has passed.

### Fleet state and safety

- An unreadable `fleet.json`, `project-images.json` or scale-set session file is no longer silently replaced. It is moved
  aside to `<name>.corrupt-<timestamp>`, kinhin starts empty, and the app and `kinhin status` name the kept copy.
- "Reset everything" no longer reports success when something is left behind. `kinhin reset` exits 1 in that case and the
  app's status line lists what remains.
- The disk check before a Tart clone uses the size of the image being cloned, so a large `images:` image no longer passes as
  if it were the base VM.
- A named image that has not been prepared no longer triggers a `tart list` on every poll.
- Core toolchains (`node`, `go`, `python`, `ruby`, `swift`) install a pinned default when listed without a version, so a
  re-bake reproduces the same versions.
- A repository's config now lives at `.kinhin/config.yml`. The older `.kinhin.yml` is still read when the new file is absent.
- Output from child processes is read to the end of the pipes before a command returns, so stderr is no longer cut short
  under load.

### What this means for the forges

This release's changelog has no forge-specific code fix. What it hardens for the forges is the testing around them (the
end-to-end suite and, if it passes, the GitHub lane) and the fleet they run on: state that is no longer silently replaced, a
reset that reports what it left, and healing for warm VMs and detached accounts.

TODO(verify:T5): if beta-2 testing produced a forge code change, name it here with the test that covers it. Do not write
"forge fixes" without one.

## Should you use it now?

**Yes, if** you run GitHub Actions, Gitea, Forgejo or GitLab CE, have an Apple Silicon Mac you control, and mostly run your
own trusted code. One caveat for older Gitea servers: Gitea 1.24 and earlier show no queued job to the API until a runner
exists, so you must set `min_runners: 1` (one warm runner). Gitea 1.25+ and Forgejo 11 list queued jobs themselves.

**Not yet, if** you need Buildkite, Azure Pipelines or Bitbucket Pipelines. They are planned for a later release.

**Be careful, whatever you use, if** the code you run is not yours. A VM boundary is real isolation. Docker is weaker (a
shared kernel and default capabilities). Host mode has no isolation at all. The shared toolchain cache is writable and
trusted by later jobs, so it defaults to off. If you run fork PRs or outside contributors' code, turn on the settings in
the [security guide](/guide/security#if-you-run-untrusted-prs-turn-these-on) first and read the
[known limits](/guide/security#known-limits). For a public repository, the
[open-source guide](/guide/open-source) shows how to keep fork pull requests off your Mac entirely.

### Try it

<!-- GATE:G6 start -->
```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

The installer verifies a signed, notarized DMG, installs `kinhin.app` and links the `kinhin` CLI.
<!-- GATE:G6 end -->
<!-- FALLBACK:G6 start -->
The install command goes here once the beta-2 release is published and its install script has been checked.
<!-- FALLBACK:G6 end -->

You need an Apple Silicon Mac on macOS 15 or newer with about 60 GB of free disk, and an access token for your forge. The
[Quick start](/guide/quick-start) goes from install to a running fleet, and [Hardware and sizing](/guide/hardware) helps
you decide how big a Mac you need.

<!-- GATE:T6 start -->
Upgrading from beta 1 was checked on a Mac with real beta-1 state (fleet, project images and repository config). Nothing was
lost or silently reset.
<!-- GATE:T6 end -->
<!-- FALLBACK:T6 start -->
Upgrading from beta 1 has not been checked on a Mac with real state. Before you upgrade, copy your config and fleet files
somewhere safe.
<!-- FALLBACK:T6 end -->

## What has been tested, and what has not

I use two words precisely:

- **Live-tested** means it was run against a real server, with a real workflow job, on a real Mac.
- **Unit-tested only** means automated tests against fakes, stubbed HTTP and fake shells, and **never run against a real
  instance**. Those tests show the code matches my reading of an API, not that the real service agrees. Buildkite, Azure
  Pipelines and Bitbucket Pipelines are at this stage, which is why they are not supported yet.

| Area | State at beta-2 |
| ---- | --------------- |
| GitHub Actions + Tart macOS VMs, apple/container | <!-- GATE:T5 start -->Live-tested, by the end-to-end suite's GitHub lane against a throwaway repository<!-- GATE:T5 end --><!-- FALLBACK:T5 start -->Live-tested by hand on beta 1. The GitHub lane has not been run against a throwaway repository for this release<!-- FALLBACK:T5 end --> |
| Gitea (1.24, 1.26), Forgejo 11, GitLab CE 18.4 on Tart macOS and Linux VMs, apple/container, Docker, host mode | <!-- GATE:T2 start -->Live-tested, by the end-to-end suite, on the release commit<!-- GATE:T2 end --><!-- FALLBACK:T2 start -->Live-tested, by the end-to-end suite, on beta 1 (2026-10-10). Not re-run on this release<!-- FALLBACK:T2 end --> |
| Crash recovery, concurrency cap, pause and resume, forge outages, warm pool, routing | <!-- GATE:T2 start -->Live-tested, by the end-to-end suite, on the release commit<!-- GATE:T2 end --><!-- FALLBACK:T2 start -->Live-tested on beta 1. Not re-run on this release<!-- FALLBACK:T2 end --> |
| Toolchain installs (baked and per job) | <!-- GATE:T2 start -->Live-tested, by the end-to-end suite, on the release commit<!-- GATE:T2 end --><!-- FALLBACK:T2 start -->Live-tested on beta 1. Not re-run on this release<!-- FALLBACK:T2 end --> |
| Warm pools per image (`warm_pool` on an `images:` entry) | <!-- GATE:T2 start -->Live-tested, by the end-to-end suite<!-- GATE:T2 end --><!-- FALLBACK:T2 start -->Unit-tested only<!-- FALLBACK:T2 end --> |
| Healing agent: the four automatic cases | <!-- GATE:T3 start -->Live-tested, on my own Mac<!-- GATE:T3 end --><!-- FALLBACK:T3 start -->Unit-tested only<!-- FALLBACK:T3 end --> |
| Upgrade from beta 1 with real state | <!-- GATE:T6 start -->Checked on a Mac with real beta-1 state<!-- GATE:T6 end --><!-- FALLBACK:T6 start -->Not checked<!-- FALLBACK:T6 end --> |
| Launch video (video suite) | <!-- GATE:T7 start -->Built and checked<!-- GATE:T7 end --><!-- FALLBACK:T7 start -->Not in this release<!-- FALLBACK:T7 end --> |
| Mobile fastlane and screenshots scaffolding | Not in this release's live gates |
| Buildkite, Azure Pipelines, Bitbucket Pipelines | Planned, not supported yet |
| In-app updater against a published release | Not exercised yet. It runs once this release is out, from an installed beta 1 |
| End-to-end suite nightly on a dedicated Mac | Not running yet |
| ThreadSanitizer | <!-- GATE:T4 start -->One clean run of `scripts/tsan.sh` on the release commit<!-- GATE:T4 end --><!-- FALLBACK:T4 start -->Not run on this release. The last clean run was beta 1's (2026-10-10). The healing agent and per-image warm pools are the new shared-state code that most needs it<!-- FALLBACK:T4 end --> |
| Long-running soak test | Not done |

There are about [MEASURE: unit-test count] unit tests that need no VMs or network. They run in about [MEASURE: wall time
with --parallel], and they are not evidence that the real services agree with me.

The boot and build timings from beta 1 are in [that post](/blog/introducing-kinhin-beta). They were measured on beta 1 and
are not repeated here.

### The end-to-end suite

"Live-tested" is not me, by hand, once. An automated end-to-end suite (`scripts/e2e.sh`, described in the
[e2e docs](https://github.com/RabinApps/kinhin/blob/main/docs/e2e-testing.md)) starts a real Gitea, Forgejo or GitLab CE
in a container, runs a real kinhin daemon against it in a sandbox that cannot touch my own setup, bakes a real runner
image, pushes a workflow, and then checks what the forge itself reports: the job ran inside the guest (it files an issue
containing the guest's kernel and hostname), the instance was deleted afterwards, the runner was deregistered, and no
token reached the log. It runs Gitea, Forgejo and GitLab CE on every runtime, plus failing jobs, long jobs, a daemon killed
mid-run, a forge that hangs mid-job, the concurrency cap, the warm pool, routing, and toolchain installs.

<!-- GATE:T5 start -->
This release's GitHub lane ran against a throwaway repository, so GitHub's live runs are no longer only mine.
<!-- GATE:T5 end -->
<!-- FALLBACK:T5 start -->
The GitHub lane needs a throwaway repository and a token. It has not been run for this release, so GitHub's live runs are
still my own.
<!-- FALLBACK:T5 end -->

## How this was built

Because agents type the code, the checks carry the weight. Every change has to pass `scripts/check.sh` (build, the unit
suite, format, docs and skills lint). The end-to-end suite runs real software rather than fakes, and anything that touches
shared state also gets a ThreadSanitizer run. Beta 2 adds more shared state than beta 1 did, with the healing agent and the
per-image warm pools, so the TSan run matters more this time.

<!-- GATE:T1 start -->
`scripts/check.sh` is green on the release commit.
<!-- GATE:T1 end -->
<!-- FALLBACK:T1 start -->
I have not yet got a green `scripts/check.sh` run on the release commit, and I am not claiming one.
<!-- FALLBACK:T1 end -->

Weigh all of that however you like. It is also why the testing table above is as blunt as it is.

## Where I need help

I have one Mac, one GitHub setup, and a finite supply of evenings. The fastest way to improve this beta is to run the parts
I could not. In rough order of value:

1. **Real projects on the supported forges.** Your workflows, not my test jobs: GitHub, Gitea, Forgejo and GitLab CE.
2. **The updater.** Install beta 1, let it find this release, and tell me whether it installed the update.
3. **The healing agent.** Run `kinhin heal` on a real fleet and send me the journal entries that look wrong.
4. **Other versions:** newer Forgejo, Gitea 1.25, older GitLab CE releases.
5. **GitHub on Docker and host mode**, and Docker through OrbStack or colima. I have used Docker Desktop.
6. **Mixed fleets:** more than one account or forge sharing one pool, and mixed runtimes routed by label.
7. **Different hardware:** other Mac sizes and macOS versions, especially 8 GB and 16 GB machines.
8. **Docs and first run.** If you got stuck, that is a bug in the docs or the app.

One real job is a valuable report, including when it fails.

### How to report

Open a [forge or runtime report](https://github.com/RabinApps/kinhin/issues/new/choose) and say whether it worked end to
end, partly, or failed, what you ran, and what went wrong. Attach the output of:

```bash
kinhin doctor --bundle
```

It writes a redacted bundle (doctor report, config and recent log). Tokens are masked, but please glance through it before
attaching. A good report names the forge and its version, the runtime, and the first thing that went wrong. Here is what
happens to it: I reproduce it, fix it, add a test, and once a forge or runtime has passed a real run the table above and
the docs change to say so.

## Contributing

Bug reports, feature requests and pull requests are welcome, including AI-assisted ones. The repository has an
[`AGENTS.md`](https://github.com/RabinApps/kinhin/blob/main/AGENTS.md) and a `CLAUDE.md` that point agents at the rules.
The short version: follow [CONTRIBUTING.md](/guide/contributing) exactly, run `scripts/check.sh` before opening a PR, keep
mechanical changes in separate commits, and own the change whether a human or a model typed it. You can also
[add your project to "Who uses kinhin"](/guide/used-by) or [support the project](/guide/support).

## Goals

The milestones are ordered by what has to be true, not by date. The complete version is the
[beta roadmap](/guide/beta-roadmap).

- **beta-2: hardening the supported forges.** This release. Its open items are the updater, which needs this release out
  first, and the nightly end-to-end run, which is not running yet. The GitHub lane is in the table above.
- **beta-3: more forges.** Buildkite, Azure Pipelines and Bitbucket Pipelines, each supported once it passes the same
  end-to-end runs. Mixed-forge fleets.
- **Release candidate: hardening.** ThreadSanitizer still clean, a long soak test with no leaked VMs, containers or
  registered runners, and the known limits reviewed against what testers hit.
- **v0.1.0.** A signed, notarized release with a working updater path, and a docs snapshot under the version picker.

## Windows

Windows runners are not part of the beta and I'm not promising them for v0.1.0. Windows containers aren't possible on this
stack, which leaves Windows on ARM virtual machines, a new runtime with its own VM lifecycle, guest access, images and
runner install per forge. There is a design sketch in the repository, and the hypervisor options are constrained and, in the
Parallels case, need a paid license and install media. If Windows matters to you, open an issue describing your forge,
concurrency and hypervisor. It won't be called supported until it has run for real.

## Principles

The principles stay fixed: jobs are ephemeral by default, the scaler never starves your Mac, credentials stay in the
Keychain, there is no telemetry, and one engine serves every forge.

## Thank you

kinhin is free, Apache-2.0, and built by one developer with AI agents. If it saves you CI minutes you can
[support it](/guide/support) through GitHub Sponsors, PayPal or Buy Me a Coffee. Sponsorship supports the project and does
not buy influence over the roadmap.

- [Install and Quick start](/guide/quick-start)
- [What has been tested](/guide/forges#what-has-been-tested) and the [beta roadmap](/guide/beta-roadmap)
- [kinhin on GitHub](https://github.com/RabinApps/kinhin) and the [issue templates](https://github.com/RabinApps/kinhin/issues/new/choose)

And if a job runs on your Mac and you didn't have to babysit it, that's the whole point.

_Alex_
