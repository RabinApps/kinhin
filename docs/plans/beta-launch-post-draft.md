---
title: Introducing the kinhin beta
description: The first public beta of kinhin, the mindful CI for your Mac. What works today, what doesn't, who should try it now, and how it was tested.
sidebar: false
aside: false
---

<!--
DRAFT for Sunday, October 11, 2026. NOT for publishing as-is. The gates G1 to G10 and the optional O1 to O6 are defined in
docs/plans/beta-launch-checklist.md. Each gate has a target block (GATE:Gn start/end markers) and a fallback block
(FALLBACK:Gn start/end markers). Keep exactly one, delete the other, markers included. All [MEASURE: ...]
placeholders and TODO(verify:...) comments must be resolved or removed. Nothing here is true until its gate passed.
-->

# Introducing the kinhin beta

_Sunday, October 11, 2026 · Alex Rabin_

**kinhin** watches your CI queue and, for each queued job, starts a fresh VM or container on your Apple Silicon Mac,
registers a one-job runner, lets it run, then deletes it. Nothing idles and nothing is left over. It is free, open source
(Apache-2.0), and sends no telemetry. Today is the first public beta, `v0.0.1-beta-1`.

It is a beta, and the honest summary is short:

|                             | State today                                                                                                                                                                                                                |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Supported, run for real** | GitHub Actions, Gitea Actions, Forgejo Actions and GitLab CE. Gitea, Forgejo and GitLab run on every runtime (Tart macOS and Linux VMs, apple/container, Docker, host mode); GitHub on Tart macOS VMs and apple/container. |
| **Planned**                 | Buildkite, Azure Pipelines and Bitbucket Pipelines, in a later release.                                                                                                                                                    |
| **Hard limit**              | Apple allows two macOS guest VMs at once on a Mac, whatever the hardware. Linux containers are not capped by it.                                                                                                           |

If you only read one more section, read [Should you use it now?](#should-you-use-it-now). The rest is detail.

## Who I am, and why I built it

I'm Alex Rabin. I have been writing code since I was 15, and I have a full-time programming job. You can find more at
[alexrabin.com](https://www.alexrabin.com). My previous project is [SupDesk](https://supdesk.app/en), a feedback and
support console for solo founders and small teams.

I set up self-hosted CI twice in three months, and the second time is why kinhin exists.

About three months ago, at my full-time job, I set up a self-hosted Gitea runner for our Flutter apps. One machine had to
build for iOS, Android and the web, so every toolchain went in by hand: Xcode and CocoaPods, the Android SDK, Chrome for
web builds, and FVM to pin each project's Flutter version. It worked, and it took far longer than it should have.

Then my own projects needed the same thing. I run their CI on GitHub Actions and kept hitting the free monthly minutes.
Mac minutes are the expensive ones, and I need them for anything Apple-related. Self-hosting fixes the cost, but it meant
doing all of that setup again on a different forge, and I didn't want to do it ever again.

A plain self-hosted runner also only fixes the cost. It runs one job at a time, and the usual fixes each have a catch:
many runners on one OS share a filesystem and ports, long-lived VMs idle on your RAM and disk, and hand-rolled autoscaler
scripts have to be rewritten per CI platform. kinhin is the tool I wanted both times: one engine that handles the
scaling, the isolation and the toolchains, whichever forge the jobs come from. The longer write-up is on
[Why kinhin](/guide/why-kinhin).

## What kinhin is

At its core, kinhin is an autoscaler for ephemeral CI runners that live on one Mac.

- **Runtimes.** macOS jobs run in [Tart](https://tart.run) VMs. Linux jobs can run in
  [apple/container](https://github.com/apple/container) microVMs, Docker containers, or Tart Linux VMs. Which runtime a
  job gets is routed per repo, per workflow, or by `runs-on:` label. An opt-in host mode runs jobs directly on the Mac
  with no isolation, behind an explicit consent flag.
- **Forges.** One pool can serve GitHub Actions, GitLab CI/CD, and Gitea and Forgejo Actions. Buildkite, Azure Pipelines
  and Bitbucket Pipelines are next. Adding another is a documented, step-by-step job
  ([adding a forge](https://github.com/RabinApps/kinhin/blob/main/docs/adding-a-forge.md)).
- **Resource awareness.** The scaler works out how many instances your Mac can hold from its cores, memory and free disk,
  after reserving headroom. `kinhin doctor` shows the number ([scaling](/guide/scaling)).
- **Toolchains.** Bake tools into the image, pin them per repository, or install them per job, with an opt-in shared
  cache ([toolchains](/guide/toolchains)).
- **How you run it.** A menu bar app with a setup wizard, a full CLI, and a LaunchAgent daemon. Same engine, same config,
  one fleet. Tokens live in the macOS Keychain, not in the config file.

The name is deliberate. _Kinhin_ is walking meditation: slow, deliberate steps between sittings. Here the steps are a job
arriving, a runner being born, serving, and being released.

### How it compares

kinhin is not the only tool in this space, and for some setups it is the wrong one. runscaler, Cilicon, Tartelet, Anka,
Orka and GitLab's Tart executor each solve part of the same problem, and the
[comparison page](/guide/compare) says what each does and where kinhin is missing something. Rough guide:

- **Only GitHub:** read the comparison before choosing kinhin over a tool built only for GitHub.
- **You need many Macs behind one scheduler, or a commercial support contract:** that is Orchard, Anka or Orka. kinhin runs
  one fleet on one Mac.
- **You need Windows:** kinhin does not do Windows (see the end of this post).

## Should you use it now?

**Yes, if** you run GitHub Actions, Gitea, Forgejo or GitLab CE, have an Apple Silicon Mac you control, and mostly run
your own trusted code. One caveat for older Gitea servers: Gitea 1.24 and earlier show no queued job to the API until a
runner exists, so you must set `min_runners: 1` (one warm runner). Gitea 1.25+ and Forgejo 11 list queued jobs
themselves.

**Not yet, if** you need Buildkite, Azure Pipelines or Bitbucket Pipelines. They are planned for a later release.

**Be careful, whatever you use, if** the code you run is not yours. A VM boundary is real isolation. Docker is weaker (a
shared kernel and default capabilities). Host mode has no isolation at all. The shared toolchain cache is writable and
trusted by later jobs, so it defaults to off. If you run fork PRs or outside contributors' code, turn on the settings in
the [security guide](/guide/security#if-you-run-untrusted-prs-turn-these-on) first and read the
[known limits](/guide/security#known-limits).

### Try it

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

The installer verifies a signed, notarized DMG, installs `kinhin.app` and links the `kinhin` CLI.

You need an Apple Silicon Mac on macOS 15 or newer with about 60 GB of free disk, and an access token for your forge. The
[Quick start](/guide/quick-start) goes from install to a running fleet, and [Hardware and sizing](/guide/hardware) helps
you decide how big a Mac you need.

## What has been tested, and what has not

I use two words precisely:

- **Live-tested** means it was run against a real server, with a real workflow job, on a real Mac.
- **Unit-tested only** means automated tests against fakes, stubbed HTTP and fake shells, and **never run against a real
  instance**. Those tests show the code matches my reading of an API, not that the real service agrees.

| Area                                                                                                           | State at beta-1                           |
| -------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| GitHub Actions + Tart macOS VMs, apple/container                                                               | Live-tested, by hand                      |
| Gitea (1.24, 1.26), Forgejo 11, GitLab CE 18.4 on Tart macOS and Linux VMs, apple/container, Docker, host mode | Live-tested, by the end-to-end suite      |
| Crash recovery, concurrency cap, pause and resume, forge outages, warm pool, routing                           | Live-tested, by the end-to-end suite      |
| Toolchain installs (baked and per job)                                                                         | Live-tested, by the end-to-end suite      |
| Buildkite, Azure Pipelines, Bitbucket Pipelines                                                                | Planned, not supported yet                |
| In-app updater against a published release                                                                     | Not exercised (this is the first release) |
| ThreadSanitizer                                                                                                | One clean run of `scripts/tsan.sh`        |
| Long-running soak test                                                                                         | Not done                                  |

There are about 2,900 unit tests that need no VMs or network. They run in two minutes and they are not evidence that the
real services agree with me. Measured on my own Mac (M1 Max, 64 GB, macOS 27) with `kinhin bench`: a Tart macOS VM boots to SSH-ready in about 31 s cold and 10 s warm, an apple/container Linux container is ready in about 1.4 s, and a small Xcode project builds in 13 s clean and 3.5 s incremental inside the VM. One machine, one afternoon: treat these as a sample, not a benchmark.

### The end-to-end suite

"Live-tested" is not me, by hand, once. An automated end-to-end suite (`scripts/e2e.sh`, described in the
[e2e docs](https://github.com/RabinApps/kinhin/blob/main/docs/e2e-testing.md)) starts a real Gitea, Forgejo or GitLab CE
in a container, runs a real kinhin daemon against it in a sandbox that cannot touch my own setup, bakes a real runner
image, pushes a workflow, and then checks what the forge itself reports: the job ran inside the guest (it files an issue
containing the guest's kernel and hostname), the instance was deleted afterwards, the runner was deregistered, and no
token reached the log. It runs every forge on every runtime, plus failing jobs, long jobs, a daemon killed mid-run, a
forge that hangs mid-job, the concurrency cap, the warm pool, routing, and toolchain installs. The GitHub lane needs a
throwaway repository and a token, so GitHub's live runs are still my own.

## How this was built

I don't write code by hand anymore. I build with AI agents, primarily from Claude and Freebuff, and I only use models that
don't train on my data. I decide what gets built and I review and test the result, and the agents type the code. In
practice that means every change has to pass `scripts/check.sh` (build, the unit suite, format, docs and skills lint), the
e2e suite is the part that runs real software rather than fakes, and anything that touches shared state also gets a
ThreadSanitizer run. `scripts/check.sh` is green on the release commit. You should weigh all of this however you like. It is also why the testing table above is as blunt as it is.

## Where I need help

I have one Mac, one GitHub setup, and a finite supply of evenings. The fastest way to improve this beta is to run the parts
I could not. In rough order of value:

1. **Real projects on the supported forges.** Your workflows, not my test jobs: GitHub, Gitea, Forgejo and GitLab CE.
2. **Other versions:** newer Forgejo, Gitea 1.25, older GitLab CE releases.
3. **GitHub on Docker and host mode**, and Docker through OrbStack or colima. I have used Docker Desktop.
4. **Mixed fleets:** more than one account or forge sharing one pool, and mixed runtimes routed by label.
5. **Different hardware:** other Mac sizes and macOS versions, especially 8 GB and 16 GB machines.
6. **The updater**, once a later release is published.
7. **Docs and first run.** If you got stuck, that is a bug in the docs or the app.

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

The goal of this beta is narrow: make the four supported forges solid on real projects, then add the next ones. The
milestones are ordered by what has to be true, not by date; the complete version is the
[beta roadmap](/guide/beta-roadmap).

- **beta-2: hardening the supported forges.** Fixes from beta testers, the updater exercised against a published release,
  and the e2e suite running nightly on a dedicated Mac.
- **beta-3: more forges.** Buildkite, Azure Pipelines and Bitbucket Pipelines, each supported once it passes the same
  end-to-end runs. Mixed-forge fleets.
- **Release candidate: hardening.** ThreadSanitizer still clean, a long soak test with no leaked VMs, containers or
  registered runners, and the known limits reviewed against what testers hit.
- **v0.1.0.** A signed, notarized release with a working updater path, and a docs snapshot under the version picker.

The principles stay fixed: jobs are ephemeral by default, the scaler never starves your Mac, credentials stay in the
Keychain, there is no telemetry, and one engine serves every forge.

## Windows

Windows runners are not part of the beta and I'm not promising them for v0.1.0. Windows containers aren't possible on this
stack, which leaves Windows on ARM virtual machines, a new runtime with its own VM lifecycle, guest access, images and
runner install per forge. There is a design sketch in the repository, and the hypervisor options are constrained and, in the
Parallels case, need a paid license and install media. If Windows matters to you, open an issue describing your forge,
concurrency and hypervisor. It won't be called supported until it has run for real.

## Thank you

kinhin is free, Apache-2.0, and built by one developer with AI agents. If it saves you CI minutes you can
[support it](/guide/support) through GitHub Sponsors, PayPal or Buy Me a Coffee. Sponsorship supports the project and does
not buy influence over the roadmap.

- [Install and Quick start](/guide/quick-start)
- [What has been tested](/guide/forges#what-has-been-tested) and the [beta roadmap](/guide/beta-roadmap)
- [kinhin on GitHub](https://github.com/RabinApps/kinhin) and the [issue templates](https://github.com/RabinApps/kinhin/issues/new/choose)

And if a job runs on your Mac and you didn't have to babysit it, that's the whole point.

_Alex_
