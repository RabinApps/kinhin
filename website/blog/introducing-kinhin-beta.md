---
title: Introducing the kinhin beta
description: The first public beta of kinhin, the mindful CI for your Mac. What it is, why I built it, what has been tested for real, and where I need your help.
sidebar: false
aside: false
---

# Introducing the kinhin beta

*Saturday, October 10, 2026 · Alex Rabin*

Today I'm releasing the first public beta of kinhin (`v0.0.1-beta-1`). It is free, open source (Apache-2.0), and sends no
telemetry. This post covers who I am, why I built it, what it does, and, most importantly for a beta, what has actually
been tested and what still needs people who aren't me.

If you only read one section, read [What has been tested](#what-has-been-tested-and-what-has-not). A lot of this code is
verified only against fakes, and I would rather tell you that up front than have you find out at 2 a.m. with a broken
pipeline. The list got a little shorter this week: I built an end-to-end test suite, ran it, and it found real bugs.

## Who I am

I'm Alex Rabin. I have been writing code since I was 15. These days I have a full-time programming job, and I still
love building things outside of work, so I have a habit of starting side projects that turn into real products. You can
find more about me at [alexrabin.com](https://www.alexrabin.com).

My most recent project before this was [SupDesk](https://supdesk.app/en), a feedback and support console for solo
founders, developers and small teams. It puts a public feedback and changelog portal, private messaging, live chat and
help-center articles in one inbox, and it prices per teammate rather than per customer. I built it because the tools
aimed at bigger companies were more than a solo founder needs, and the cheap ones were missing pieces.

kinhin comes from the same place. I ran into a wall, looked for a tool, didn't find the one I wanted, and built it.

## Why kinhin exists

SupDesk and my other projects build and test in CI, and I use GitHub Actions. Then I ran into the limits of the free
monthly minutes. Mac builds are the painful ones, because they are the most expensive way to spend those minutes, and
they are exactly what I need for anything Apple-related.

The obvious answer is a self-hosted runner: I have a Mac, so point CI at it. That works until you want two things to run at
once. A self-hosted runner does one job at a time. Register one runner on your Mac and every other job waits in line
behind it. I wanted real concurrency, not a queue.

The textbook fix is to run many runners, and then you meet the problems that come with that:

- Several runners on one OS share a filesystem, ports and toolchain caches, so jobs collide and state leaks between builds.
- Long-lived VMs per runner isolate better, but they sit on RAM and disk all day, even when nothing is queued.
- Hand-rolled autoscaler scripts are glue that has to be rewritten for every CI platform.
- macOS adds its own ceiling: Apple's license and virtualization framework allow only two macOS guest VMs at once on a
  Mac, so "one VM per runner" tops out at two.

kinhin is my answer to all four. It watches your queues, and for each queued job it creates a fresh VM or container,
registers an ephemeral runner, lets it run exactly one job, then deregisters the runner and deletes the instance.
Nothing is left over and nothing idles. The longer write-up, with a table of how each CI platform limits concurrency,
is on the [Why kinhin](/guide/why-kinhin) page.

The name is deliberate. *Kinhin* is walking meditation: slow, deliberate steps between sittings. Here the steps are a job
arriving, a runner being born, serving, and being released. The product is meant to feel calm, and to stay out of your way.

## What kinhin is

At its core, kinhin is an autoscaler for ephemeral CI runners that live on an Apple Silicon Mac.

**Runtimes.** macOS jobs run in [Tart](https://tart.run) VMs. Linux jobs can run in
[apple/container](https://github.com/apple/container) microVMs, Docker containers, or Tart Linux VMs. For fully trusted
repositories there is an opt-in host mode that runs jobs directly on the Mac with no isolation at all, behind an explicit
consent flag. Which runtime a job gets is routed per repo, per workflow, or by `runs-on:` label.

**Forges.** One shared pool can serve GitHub Actions, GitLab CI/CD, Gitea and Forgejo Actions, Buildkite, Azure
Pipelines and Bitbucket Pipelines. The forge abstraction is written so adding another one is a documented, step by step
job ([adding a forge](https://github.com/RabinApps/kinhin/blob/main/docs/adding-a-forge.md)).

**Resource awareness.** The scaler computes how many instances your Mac can really hold from its cores, memory and free
disk, after reserving headroom so the machine stays usable. `kinhin doctor` shows you that number. The
[scaling guide](/guide/scaling) explains the math.

**Toolchains.** Bake your tools into the image, pin them per repository, or install them per job. A shared, opt-in cache
speeds repeat installs ([toolchains](/guide/toolchains)).

**How you run it.** There is a menu bar app with a setup wizard, a full CLI, and a LaunchAgent daemon. They are the same
engine with the same config, and there is only ever one fleet. Tokens live in the macOS Keychain, not in the config file.

**Other things I care about.** Every job gets a freshly cloned VM by default. Logs redact every token format kinhin knows
about. `kinhin doctor --bundle` writes a redacted support bundle you can attach to a bug report. There are
[agent skills and an MCP surface](/guide/agents) so your own coding agent can operate kinhin safely. And there is no
telemetry, none.

### Try it

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

The installer verifies a signed, notarized DMG, installs `kinhin.app` and links the `kinhin` CLI. You need an Apple Silicon
Mac on macOS 15 or newer with about 60 GB of free disk, and an access token for your forge. The
[Quick start](/guide/quick-start) takes you from install to a running fleet, and [Hardware and sizing](/guide/hardware)
helps you decide how big a Mac you need for the concurrency you want.

## What has been tested, and what has not

A beta label means little unless it comes with specifics, so here they are. I use two words precisely:

- **Live-tested** means it was run against a real server, with a real workflow job, on a real Mac.
- **Unit-tested only** means the code has automated tests against fakes, stubbed HTTP responses and fake shells, and has
  **never been run against a real instance**. Those tests show the code matches my reading of an API. They do not show
  the real service agrees with me.

| Area | State at beta-1 |
| ---- | --------------- |
| GitHub Actions + Tart macOS VMs | Live-tested |
| GitHub Actions + apple/container (Linux jobs) | Live-tested |
| Gitea Actions + Docker containers (Linux jobs) | Live-tested, by the new end-to-end suite (Gitea 1.24) |
| Forgejo | Unit-tested only (same code path as Gitea; the e2e fixture exists, a passing run is not yet recorded) |
| GitLab (gitlab.com and self-managed) | Unit-tested only |
| Buildkite, Azure DevOps, Bitbucket | Unit-tested only |
| Docker runtime | Live-tested with Gitea only; GitHub and the other forges on Docker are unit-tested only |
| Tart Linux VM runtime | Unit-tested only |
| Host mode | Unit-tested only |
| In-app updater against a published release | Not exercised (this release is the first one) |
| Crash recovery (daemon killed, orphans reconciled) | Covered by the e2e suite; not yet recorded as a passing run |
| Long-running soak test at scale | Not done yet |
| ThreadSanitizer run on the full suite | Not yet part of a signed-off pass (it is a release candidate item) |

So the honest summary is: **two forges have been run for real: GitHub Actions (Tart and apple/container) and Gitea
Actions (Docker).** Everything else exists, is covered by a large automated suite (around 2,300 tests that need no VMs or
network), and may well work, but I have not watched it work.

### The end-to-end suite

Until this week "live-tested" meant me, by hand, once. Just before release I wrote an automated end-to-end suite
(`scripts/e2e.sh`, described in [the e2e docs](https://github.com/RabinApps/kinhin/blob/main/docs/e2e-testing.md)). It
starts a real Gitea in a container, runs a real kinhin daemon against it in a sandbox that cannot touch my own setup,
bakes a real runner image, pushes a workflow, and then checks what the forge itself reports: the job ran inside the
guest (it files an issue containing the guest's kernel and hostname), the instance was deleted afterwards, the runner
was deregistered, and no token reached the log. It also runs a job that fails on purpose and checks the fleet recovers.
Gitea on Docker passes both. The suite also has CLI, security and "every forge and command is accounted for" checks,
and fixtures for Forgejo, GitLab CE and (with credentials) GitHub. I have **not** run the GitLab or GitHub fixtures yet:
the GitLab image would not fit in my Docker disk, and GitHub needs a throwaway repository.

### Why I keep saying "unit-tested is not tested"

Because the live runs found real bugs that no unit test would have. The first real Gitea job, run this week, found
four more, and several existing unit tests had been pinning the wrong behavior as correct:

- **`kinhin start` crashed on launch on macOS 27.** It parked the main thread with `dispatchMain()`, which libdispatch now
  refuses when called from the main queue. It now waits on a continuation instead.
- **Gitea and Forgejo runners were registered with the wrong program.** In containers the script ran the GitHub runner's
  `config.sh`, which does not exist in a Gitea image, and the macOS script called `gitea-runner run` and
  `gitea-runner remove`, which that runner does not have. Its CLI is `register`, then `daemon`. The unit tests asserted
  the wrong scripts, one with a comment admitting it.
- **A Docker pool never advertised `kinhin-docker`** for Gitea, because the account's labels overrode the pool's, so
  `runs-on: kinhin-docker` could never match.
- **`kinhin config init` failed on a fresh machine** (the support folder did not exist yet) and wrote the config readable
  by other users.

One limitation came out of it too: Gitea 1.24 does not report a queued job to the API until a runner exists, so with
`min_runners: 0` kinhin cannot see the work. Gitea needs `min_runners: 1` (one warm runner) for now. A newer Gitea has an
endpoint for this, and using it is on the list.

The earlier ones came from my own test pass on October 1:

- **GitHub organization runners returned a 404 on registration.** The registration URL I had built for an org scope was
  wrong. The fake server accepted it, the real one did not.
- **SSH was not ready when I thought it was.** `tart ip` answers about 20 seconds before the guest's sshd actually
  listens, so registration failed with a timeout. It now retries for up to two minutes.
- **Org scope could not see most of an organization's repositories.** Only the first 20 repos in API order were read, so a
  queued job in the 28th repo was invisible. Repositories are now read most recently pushed first, and I checked the
  queue counts against `gh` by hand.
- **A Tart CLI output change broke image detection.** `tart list --quiet` now prints only names, so a prepared image was
  never found and the next bake failed with "already exists".
- **Toolchains shadowed each other.** The guest's Homebrew `node` came ahead of the pinned one on `PATH`, so a job asked for
  Node 22 and got 24. The bake now puts the version manager's shims first.
- **Default NAT networking did not work for one guest on macOS 27.** The guest got a lease but the host could not reach
  it, while bridged mode worked. I suspect the host's networking rather than kinhin, but a user would have hit it.
- **A default base image was not pullable anonymously.** One registry returned 403, so the default now points somewhere
  that works.

Every one of those was found by running the real thing, and the unit suite did not. That is the whole reason I expect the
untested forges to have their own surprises, and why I'm asking for help below. The full running notes are in the
[beta roadmap](/guide/beta-roadmap) and the forge matrix is in [what has been tested](/guide/forges#what-has-been-tested).

### Known limits

Beyond testing coverage, kinhin has documented limits you should read before pointing it at untrusted code. The short
version: a VM boundary is real isolation, Docker is weaker (shared kernel, default capabilities), the shared toolchain
cache is writable and trusted by later jobs so it defaults to off, and host mode has no isolation. If you run fork PRs
or outside contributors' code, turn on the settings in the
[security guide](/guide/security#if-you-run-untrusted-prs-turn-these-on) and read the
[known limits](/guide/security#known-limits).

## Where I need help

I have one Mac, one GitHub setup, and a finite supply of evenings. The fastest way to make this beta better is for you to
run the parts I could not. In rough order of value:

1. **Gitea and Forgejo on other versions and runtimes.** I have run Gitea 1.24 on Docker. I want Forgejo, newer Gitea
   (1.25 and later report queued jobs differently), and Gitea on Tart and apple/container.
2. **GitLab.** Both gitlab.com and a self-managed instance. They differ, and I have run neither. A fixture for GitLab CE
   exists in the e2e suite, but I could not fit the image in my Docker disk, so it has never run.
3. **Docker for Linux jobs.** I have run it with Docker Desktop and Gitea. Tell me about OrbStack or colima, and about
   GitHub or GitLab jobs on Docker.
4. **Buildkite, Azure DevOps and Bitbucket Pipelines.** Real accounts, even a free tier and a single job.
5. **Mixed fleets.** More than one account or forge sharing one pool, and mixed runtimes routed by label.
6. **Different hardware.** Other Mac sizes and macOS versions, especially 8 GB and 16 GB machines, and the networking
   modes your setup needs.
7. **The updater.** When a later release is published, confirm that the in-app update path actually moves you forward.
8. **Docs and first-run experience.** If you got stuck, that is a bug in the docs or the app. Tell me where.

You do not need to run anything for long. One job through a forge I haven't touched is a genuinely valuable report,
including (maybe especially) when it fails.

### How to report

Open a [forge or runtime report](https://github.com/RabinApps/kinhin/issues/new/choose) and say whether it worked end to
end, partly, or failed, what you ran, and what went wrong. Attach the output of:

```bash
kinhin doctor --bundle
```

It writes a redacted bundle (doctor report, config and recent log) and tokens are masked. Please still glance through it
before attaching. Reports are what move a forge from "unit-tested" to "live-tested" in the table above, and I'll
update the docs as results come in.

## Contributing, and AI-assisted pull requests

Bug reports, feature requests and pull requests are all welcome. kinhin is built by one developer, so I read everything
and I'm glad of the help.

**AI-assisted pull requests are welcome too.** I use coding agents myself, and the repository has an
[`AGENTS.md`](https://github.com/RabinApps/kinhin/blob/main/AGENTS.md) and a `CLAUDE.md` that point agents at the right
rules. What I ask is the same thing I'd ask of any contributor:

- **Follow [CONTRIBUTING.md](/guide/contributing) exactly.** It has the build, test, format, layout, style, error handling
  and commit conventions. Don't ask the agent to guess them.
- **Run `scripts/check.sh` before you open the PR.** It is the whole CI gate in one command (build, tests, format lint,
  docs lint, docs-sync check, skills lint) and fails fast. `scripts/check.sh --fast` skips the roughly two minute test
  run while you iterate.
- **Run `scripts/tsan.sh` if you touch shared state,** actors, locks or anything marked `nonisolated(unsafe)`.
- **Keep mechanical changes separate.** Moves, renames and formatting go in their own commits, apart from behavior changes.
- **Docs live once, in `docs/`.** Don't copy a guide into `website/`, and don't hand-edit between `docs-sync` markers.
- **`skills/` is shipped product surface.** Those agent skills are for people using kinhin, not contributor notes.
  Read the "Skills" section of CONTRIBUTING.md before editing them.
- **You own the change.** Whether a human or a model typed it, read the diff, understand it, and be able to explain it in
  review. Small, focused PRs with tests are far easier to merge than large generated ones.

You don't have to write code to help. You can [add your project to "Who uses kinhin"](/guide/used-by) with one line, or
[support the project](/guide/support). Adding a new forge is a documented path if there is one you need.

## Goals

The goal of this beta is narrow: turn "unit-tested against fakes" into "run against a real server" for every forge and
runtime that ships. The milestones are ordered by what has to be true, not by date, and the complete version is the
[beta roadmap](/guide/beta-roadmap).

- **beta-2: first real-server runs.** Gitea is done on Docker. Forgejo and GitLab are next, with fixes for whatever the
  real APIs do differently. Exercise the updater against a published release. Verify Linux jobs on Docker with more
  forges, and run the end-to-end suite nightly on a dedicated Mac.
- **beta-3: the rest.** Buildkite, Azure DevOps and Bitbucket against real accounts. Docker, Tart Linux and host mode run
  for real. Mixed-forge, multi-account fleets on one pool. The exit rule is that every shipped forge and runtime is
  either live-tested or clearly labeled experimental in the docs.
- **Release candidate: hardening.** A clean ThreadSanitizer run, a long soak test (scaling up and down, crash and restart
  recovery, no leaked VMs, containers or registered runners), and the known limits reviewed against what beta testers hit.
- **v0.1.0.** A signed, notarized release with a working updater path from the last beta, and a docs snapshot under the
  version picker. No open data loss, leaked credential or leaked runner bugs.

Underneath those milestones are a few principles I intend to keep: jobs are ephemeral by default, the scaler never starves
your Mac, credentials stay in the Keychain, there is no telemetry, and one engine serves every forge.

## Windows, maybe after the production launch

People will ask, so here is where I stand. Windows runners are **not** part of the beta and I'm not promising them for
v0.1.0. They are something I'd like to look at after the production launch, if there is demand and if the pieces turn out
to be workable.

Why it isn't a quick add:

- **Windows containers aren't possible** on this stack. Linux containers run on a Linux kernel, and there is no Windows
  container path on a Mac.
- **That leaves Windows virtual machines on Apple Silicon,** which means Windows on ARM guests. kinhin's existing VM
  runtime is Tart, which boots macOS and Linux. Windows would be a new runtime with its own VM lifecycle, a way to get
  into the guest (Tart uses SSH, Windows needs an equivalent), a story for creating and distributing images, and runner
  install and registration for each forge.
- **The hypervisor options are constrained.** I've sketched a design in the repository (a Windows runtime behind a
  hypervisor abstraction, GitHub Actions first, with a scripted backend and a Parallels backend). When I probed what is
  available, a Parallels setup had its own friction, including admin credentials for creating VMs, a paid license, and
  needing Windows install media. None of that is a blocker in principle, but it means I'm not going to claim support
  I can't stand behind.

If Windows matters to you, say so: open an issue describing your use case (which forge, how many concurrent jobs, which
hypervisor you'd use). Concrete demand and people willing to test it will decide when this moves up the list. The same
test-before-claim rule that applies to everything else will apply to Windows: it won't be called supported until it has
run for real.

## Thank you

kinhin is free, Apache-2.0, and built by one developer. If it saves you CI minutes, you can
[support it](/guide/support) through GitHub Sponsors, PayPal or Buy Me a Coffee, and companies can sponsor to have their
logo shown on this site. Sponsorship supports the project and does not buy influence over the roadmap.

Thank you for trying a beta. The links you'll want:

- [Install and Quick start](/guide/quick-start)
- [What has been tested](/guide/forges#what-has-been-tested) and the [beta roadmap](/guide/beta-roadmap)
- [kinhin on GitHub](https://github.com/RabinApps/kinhin) and the [issue templates](https://github.com/RabinApps/kinhin/issues/new/choose)
- [Contributing](/guide/contributing)

And if a job runs on your Mac and you didn't have to babysit it, that's the whole point.

*Alex*
