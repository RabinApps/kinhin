---
title: Introducing the kinhin beta
description: The first public beta of kinhin, the mindful CI for your Mac. What works today, what doesn't, who should try it now, and how it was tested.
sidebar: false
aside: false
---

# Introducing the kinhin beta

*Saturday, October 10, 2026 · Alex Rabin*

**kinhin** watches your CI queue and, for each queued job, starts a fresh VM or container on your Apple Silicon Mac,
registers a one-job runner, lets it run, then deletes it. Nothing idles and nothing is left over. It is free, open source
(Apache-2.0), and sends no telemetry. Today is the first public beta, `v0.0.1-beta-1`.

It is a beta, and the honest summary is short:

|  | State today |
| -- | -- |
| **Works, run for real** | GitHub Actions on Tart macOS VMs. GitHub Actions on apple/container (Linux jobs). Gitea Actions on Docker (Linux jobs, Gitea 1.24). |
| **Written and unit-tested, never run against a real server** | Forgejo, GitLab, Buildkite, Azure DevOps, Bitbucket. Tart Linux VMs. Host mode. |
| **Hard limit** | Apple allows two macOS guest VMs at once on a Mac, whatever the hardware. Linux containers are not capped by it. |

If you only read one more section, read [Should you use it now?](#should-you-use-it-now). The rest is detail.

## What kinhin is

At its core, kinhin is an autoscaler for ephemeral CI runners that live on one Mac.

- **Runtimes.** macOS jobs run in [Tart](https://tart.run) VMs. Linux jobs can run in
  [apple/container](https://github.com/apple/container) microVMs, Docker containers, or Tart Linux VMs. Which runtime a
  job gets is routed per repo, per workflow, or by `runs-on:` label. An opt-in host mode runs jobs directly on the Mac
  with no isolation, behind an explicit consent flag.
- **Forges.** One pool can serve GitHub Actions, GitLab CI/CD, Gitea and Forgejo Actions, Buildkite, Azure Pipelines and
  Bitbucket Pipelines, subject to the testing state above. Adding another is a documented, step-by-step job
  ([adding a forge](https://github.com/RabinApps/kinhin/blob/main/docs/adding-a-forge.md)).
- **Resource awareness.** The scaler works out how many instances your Mac can hold from its cores, memory and free disk,
  after reserving headroom. `kinhin doctor` shows the number ([scaling](/guide/scaling)).
- **Toolchains.** Bake tools into the image, pin them per repository, or install them per job, with an opt-in shared
  cache ([toolchains](/guide/toolchains)).
- **How you run it.** A menu bar app with a setup wizard, a full CLI, and a LaunchAgent daemon. Same engine, same config,
  one fleet. Tokens live in the macOS Keychain, not in the config file.

The name is deliberate. *Kinhin* is walking meditation: slow, deliberate steps between sittings. Here the steps are a job
arriving, a runner being born, serving, and being released.

### Why I built it

I run my projects' CI on GitHub Actions and ran into the free monthly minutes. Mac minutes are the expensive ones, and I
need them for anything Apple-related. A self-hosted runner fixes the cost but runs one job at a time, and the usual
fixes each have a catch: many runners on one OS share a filesystem and ports, long-lived VMs idle on your RAM and disk,
and hand-rolled autoscaler scripts have to be rewritten per CI platform. kinhin is one engine that does the scaling and the
isolation for all of them. The longer write-up is on [Why kinhin](/guide/why-kinhin).

### How it compares

kinhin is not the only tool in this space, and for some setups it is the wrong one. runscaler, Cilicon, Tartelet, Anka,
Orka and GitLab's Tart executor each solve part of the same problem, and the
[comparison page](/guide/compare) says what each does and where kinhin is missing something. Rough guide:

- **Only GitHub, and you want the most mature path today:** kinhin's GitHub support is the part that has been run for real,
  but read the comparison before choosing it over a tool built only for GitHub.
- **You need many Macs behind one scheduler, or a commercial support contract:** that is Orchard, Anka or Orka. kinhin runs
  one fleet on one Mac.
- **You need Windows:** kinhin does not do Windows (see the end of this post).

## Should you use it now?

**Yes, if** you run GitHub Actions, have an Apple Silicon Mac you control, and mostly run your own trusted code. This is
the path that has been run for real, with Tart macOS VMs or apple/container for Linux.

**Maybe, if** you use Gitea with Docker for Linux jobs. It ran for real on Gitea 1.24, but there is one caveat: Gitea 1.24
shows no queued job to the API until a runner exists, so you must set `min_runners: 1` (one warm runner). Newer Gitea
reports queued jobs differently, and kinhin does not use that yet.

**Not yet, if** you need Forgejo, GitLab, Buildkite, Azure DevOps or Bitbucket, Tart Linux VMs or host mode in anything
you depend on. They are written and unit-tested, and I have not watched them work. Try them on something disposable and
tell me what happens.

**Be careful, whatever you use, if** the code you run is not yours. A VM boundary is real isolation. Docker is weaker (a
shared kernel and default capabilities). Host mode has no isolation at all. The shared toolchain cache is writable and
trusted by later jobs, so it defaults to off. If you run fork PRs or outside contributors' code, turn on the settings in
the [security guide](/guide/security#if-you-run-untrusted-prs-turn-these-on) first and read the
[known limits](/guide/security#known-limits).

### Try it

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

The installer verifies a signed, notarized DMG, installs `kinhin.app` and links the `kinhin` CLI. You need an Apple Silicon
Mac on macOS 15 or newer with about 60 GB of free disk, and an access token for your forge. The
[Quick start](/guide/quick-start) goes from install to a running fleet, and [Hardware and sizing](/guide/hardware) helps
you decide how big a Mac you need.

## What has been tested, and what has not

I use two words precisely:

- **Live-tested** means it was run against a real server, with a real workflow job, on a real Mac.
- **Unit-tested only** means automated tests against fakes, stubbed HTTP and fake shells, and **never run against a real
  instance**. Those tests show the code matches my reading of an API, not that the real service agrees.

| Area | State at beta-1 |
| ---- | --------------- |
| GitHub Actions + Tart macOS VMs | Live-tested |
| GitHub Actions + apple/container (Linux jobs) | Live-tested |
| Gitea Actions + Docker containers (Linux jobs) | Live-tested, by the end-to-end suite (Gitea 1.24) |
| Forgejo | Unit-tested only. Same code path as Gitea, and an e2e fixture exists, but there is no recorded passing run. |
| GitLab (gitlab.com and self-managed) | Unit-tested only |
| Buildkite, Azure DevOps, Bitbucket | Unit-tested only |
| Docker runtime with other forges | Unit-tested only |
| Tart Linux VM runtime, host mode | Unit-tested only |
| In-app updater against a published release | Not exercised (this is the first release) |
| Crash recovery, concurrency cap, pause and resume | Written into the e2e suite, not yet recorded as a passing run |
| Long-running soak test | Not done |

There are about 2,300 unit tests that need no VMs or network. They run in two minutes and they are not evidence that the
real services agree with me. I have no throughput, boot-time or cost figures to give you yet: `kinhin bench` exists to
produce them, and I would rather publish measured numbers later than guess now.

### The end-to-end suite

Until this week "live-tested" meant me, by hand, once. Just before release I wrote an automated end-to-end suite
(`scripts/e2e.sh`, described in the
[e2e docs](https://github.com/RabinApps/kinhin/blob/main/docs/e2e-testing.md)). It starts a real Gitea in a container,
runs a real kinhin daemon against it in a sandbox that cannot touch my own setup, bakes a real runner image, pushes a
workflow, and then checks what the forge itself reports: the job ran inside the guest (it files an issue containing the
guest's kernel and hostname), the instance was deleted afterwards, the runner was deregistered, and no token reached the
log. It also runs a job that fails on purpose and checks the fleet recovers.

What it does and does not prove: **Gitea on Docker passes both checks.** It does not prove anything for the other
forges. There are fixtures for Forgejo, GitLab CE and (with credentials) GitHub, but I have not run the GitLab one (the
image would not fit in my Docker disk) or the GitHub one (it needs a throwaway repository). The suite has had bugs of its
own: running it found a hang in its own cleanup this week, which is the same lesson again.

### What running the real thing found

The first real Gitea job found four bugs, and several unit tests had been pinning the wrong behavior as correct:

- **`kinhin start` crashed on launch on macOS 27.** It parked the main thread in a way libdispatch now refuses.
- **Gitea and Forgejo runners were registered with the wrong program.** The container script ran the GitHub runner's
  `config.sh`, which does not exist in a Gitea image, and the macOS script called commands the Gitea runner does not have.
  One unit test asserted the wrong script with a comment admitting it.
- **A Docker pool never advertised `kinhin-docker`** for Gitea, so `runs-on: kinhin-docker` could never match.
- **`kinhin config init` failed on a fresh machine** and wrote the config readable by other users.

My own pass on October 1 found others: a 404 on GitHub organization runners, SSH not being ready when `tart ip` said it
was, an organization's repositories being invisible past the first 20, and a Tart CLI change that broke image detection.
The full notes are in the [beta roadmap](/guide/beta-roadmap) and the forge matrix is in
[what has been tested](/guide/forges#what-has-been-tested).

The pattern is why I label things "unit-tested only" and why I expect the untested forges to have their own surprises.

## Who I am, and how this was built

I'm Alex Rabin. I have been writing code since I was 15, and I have a full-time programming job. You can find more at
[alexrabin.com](https://www.alexrabin.com). My previous project is [SupDesk](https://supdesk.app/en), a feedback and
support console for solo founders and small teams.

I don't write code by hand anymore. I build with AI agents, primarily from Claude and Freebuff, and I only use models that
don't train on my data. I decide what gets built and I review and test the result, and the agents type the code. In
practice that means every change has to pass `scripts/check.sh` (build, the unit suite, format, docs and skills lint), the
e2e suite is the part that runs real software rather than fakes, and anything that touches shared state also gets a
ThreadSanitizer run. You should weigh that however you like. It is also why the testing table above is as blunt as it is.

## Where I need help

I have one Mac, one GitHub setup, and a finite supply of evenings. The fastest way to improve this beta is to run the parts
I could not. In rough order of value:

1. **Forgejo, and Gitea on other versions and runtimes.** I have run Gitea 1.24 on Docker. I want Forgejo, newer Gitea
   (1.25 and later report queued jobs differently), and Gitea on Tart and apple/container.
2. **GitLab.** Both gitlab.com and a self-managed instance. They differ, and I have run neither.
3. **Docker for Linux jobs** with GitHub or GitLab, and with OrbStack or colima. I have used Docker Desktop with Gitea.
4. **Buildkite, Azure DevOps and Bitbucket Pipelines.** Real accounts, even a free tier and a single job.
5. **Mixed fleets:** more than one account or forge sharing one pool, and mixed runtimes routed by label.
6. **Different hardware:** other Mac sizes and macOS versions, especially 8 GB and 16 GB machines.
7. **The updater**, once a later release is published.
8. **Docs and first run.** If you got stuck, that is a bug in the docs or the app.

One job through a forge I haven't touched is a valuable report, including when it fails.

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

The goal of this beta is narrow: turn "unit-tested against fakes" into "run against a real server" for every forge and
runtime that ships. The milestones are ordered by what has to be true, not by date; the complete version is the
[beta roadmap](/guide/beta-roadmap).

- **beta-2: first real-server runs.** Gitea is done on Docker. Forgejo and GitLab are next, with fixes for whatever the
  real APIs do differently. Exercise the updater against a published release. Run the e2e suite nightly on a dedicated Mac.
- **beta-3: the rest.** Buildkite, Azure DevOps and Bitbucket against real accounts. Tart Linux and host mode for real.
  Mixed-forge fleets. Every shipped forge and runtime is either live-tested or clearly labeled experimental.
- **Release candidate: hardening.** A clean ThreadSanitizer run, a long soak test with no leaked VMs, containers or
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

*Alex*
