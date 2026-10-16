---
title: "Beta 2: a fleet that heals itself, warm pools per image, and videos from your repo"
description: The second public beta of kinhin, the mindful CI for your Mac. What is new in beta 2, what has been run, what has not, and where I need your help.
sidebar: false
aside: false
---

# Beta 2: a fleet that heals itself, warm pools per image, and videos from your repo

_Friday, October 16, 2026 · Alex Rabin_

**kinhin** watches your CI queue and, for each queued job, starts a fresh VM or container on your Apple Silicon Mac,
registers a one-job runner, lets it run, then deletes it. Nothing idles and nothing is left over. It is free, open source
(Apache-2.0), and sends no telemetry.

Beta 2 is the release where the fleet looks after itself a little, the warm pools get finer-grained, and your repository can
make its own launch videos. This post covers what is new, what has been run, and what has not.

## What is new

### A fleet that heals itself

Fleets break in dull ways: a warm VM gets deleted outside kinhin, a toolchain cache fills the disk, an account gets detached,
or the Apple container system stops. The healing agent now fixes four of those on its own: a warm VM deleted out of band, a
toolchain cache filling the disk, a detached account, and a stopped Apple container system.

Anything destructive waits for you. Pruning images or reinstalling a runtime goes into a journal:

- `kinhin heal` shows the journal.
- `kinhin heal approve ID` carries out a fix you have reviewed. `kinhin heal dismiss ID` closes an entry.
- The app's Diagnostics sheet has a Healing card, and a notification fires when a fix succeeds.
- It is configured under `healing:`. [docs/healing.md](https://github.com/RabinApps/kinhin/blob/main/docs/healing.md)
  describes each rule.

On macOS 26 with Apple Intelligence turned on, the on-device model can choose from the allowed fixes for a problem that no
rule covers. It only chooses among fixes that are already allowed.

### Warm pools per image

A warm pool keeps booted, unregistered VMs ready, so the next job skips the clone and the boot. Until now the pool covered
only the top-level `image:`. Beta 2 adds `warm_pool` on any `images:` entry, so a job routed to a named image such as `xcode`
gets a ready VM too. The top-level `warm_pool` still covers `image:`, and the two share `max_runners`.

Each image in the app's **More images** card has a stepper for its pool, and the Capacity view shows the base image's. Changes
are saved once the stepper settles.

A warm VM costs RAM and disk, and it holds a `max_runners` slot while it waits. Turning a pool off, or removing an `images:`
entry, recycles its VMs straight away.

### Videos from your repository

`kinhin video` makes a narrated video of your own product from `.kinhin/videos/*.yml`. You do not copy the video suite into
your repository: the build runs a published container image (Apple `container` or Docker) against your files.

- `kinhin video init`, `list` and `build` cover the basics. Each build lands in its own folder under `.kinhin/videos/out/`.
- Music, captions, themes and formats are config. `kinhin video theme new` starts a theme that extends a built-in one.
- `kinhin video music search` finds CC0 and public-domain tracks. `--license cc-by` also offers CC BY tracks and writes the
  credit line.
- `--on-fleet` builds on a runner through a generated GitHub workflow.
- The app's Fleet tab has a **Make a Video…** sheet that uses the same code, with live output.
- A `device` scene can show store screenshots as a cross-fading slideshow.

### Recording a clip of your app

`kinhin video record <app or title>` records one window of an app as a clip, with the mouse pointer left out. `--list-windows`
shows what can be recorded, and `--window ID` picks one. The first run needs Screen Recording permission for your terminal,
which you grant once in System Settings.

### Mobile releases and store screenshots

`kinhin mobile init` scaffolds release setup for iOS, Android, Flutter, React Native, native projects, Capacitor and Ionic,
Kotlin Multiplatform and .NET MAUI, with lanes, a pinned Gemfile and a manual `mobile-release` workflow for `kinhin-xcode`.
Expo gets EAS config. It is opt-in: a project that does not run it sees no change.

A `screenshots` lane captures iOS UI tests with `snapshot` and Android instrumented tests with `screengrab`, with optional
device frames and upload.

`--ci` writes a pipeline for GitLab CI, Gitea and Forgejo Actions, Bitbucket Pipelines, Azure Pipelines or Buildkite as well
as GitHub Actions. Those files run your mobile release on that system. kinhin does not scale runners for Buildkite, Azure
Pipelines or Bitbucket Pipelines yet, which is beta-3 work. Treat the generated pipelines as untested on your project until a
run of your own has passed.

### Fleet safety and fixes

- An unreadable `fleet.json`, `project-images.json` or scale-set session file is moved aside to `<name>.corrupt-<timestamp>`
  instead of being replaced. kinhin starts empty, and the app and `kinhin status` name the kept copy.
- "Reset everything" reports what it left behind, and `kinhin reset` exits 1 in that case.
- A large `images:` image is checked against its own size before a Tart clone, not the base VM's.
- A warm VM is recycled at once when its pool is turned off, instead of holding a slot for up to an hour.
- Commands that run a child process no longer lose the last lines of stderr under load.
- Video text wraps on whole words and shrinks to fit, so titles and captions stay inside the frame.
- The Capacity card's base-image rows fit their card again.

### What changed under the hood

- A repository's config now lives at `.kinhin/config.yml`. The older `.kinhin.yml` is still read when the new file is absent.
- Core toolchains (`node`, `go`, `python`, `ruby`, `swift`) install a pinned default when listed without a version, so a re-bake
  reproduces the same versions.
- The video image is pinned by digest, and Dependabot keeps it current.

## What has been run

Here is what this release has been through, in the terms I use everywhere in this post. **Run** means it was executed for
this release. **Not yet** means it has not been, and I am not claiming it.

- **Run:** the unit suite (3,377 tests, which need no VMs or network), the ThreadSanitizer run on the branch, the video
  suite's unit tests (81 of 81), and the release build's own check, which ran before signing.
- **Run:** the launch video was built from the same suite, with its size, loudness and caption checks passing.
- **Run:** the six healing scenarios on Gitea over Docker, through the end-to-end suite on 2026-10-14. The Tart warm-VM
  case has not run.
- **Not yet:** the end-to-end suite on this release, and its GitHub lane against a throwaway repository. The suite runs
  only in CI, and the CI runner for it is not registered yet.
- **Not yet:** upgrading from beta 1 on a Mac with real state.
- **Not yet:** the in-app updater has not been run against this release.

The beta-1 end-to-end results still stand for the forges as they were, but they have not been repeated on this release.

## Try it

The release is published on [GitHub](https://github.com/RabinApps/kinhin/releases/tag/v0.0.1-beta-2). Install it with:

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

You need an Apple Silicon Mac on macOS 15 or newer with about 60 GB of free disk, and an access token for your forge. The
[Quick start](/guide/quick-start) goes from install to a running fleet.

## Where I need help

I have one Mac and a finite supply of evenings. The most useful things to test are the ones I could not:

1. **The updater.** Install beta 1, let it find this release, and tell me whether it installed the update.
2. **Upgrading with real state.** Your fleet, project images and config, on beta 1, then beta 2. Tell me if anything was lost.
3. **The healing agent.** Run `kinhin heal` on a real fleet and send me any journal entry that looks wrong.
4. **Warm pools per image.** Route a job to an `images:` entry with `warm_pool` set, and tell me whether the VM was ready.
5. **Videos from your repo.** Make one with `kinhin video init` and `build`, and send me what you got.
6. **Real projects on the supported forges.** Your workflows, not my test jobs: GitHub, Gitea, Forgejo and GitLab CE.

One real job is a valuable report, including when it fails. Open a
[forge or runtime report](https://github.com/RabinApps/kinhin/issues/new/choose) and say what you ran and what went wrong.
Attach the output of `kinhin doctor --bundle` after a glance through it, since it is redacted but not perfect.

## Thank you

kinhin is free and Apache-2.0. If it saves you CI minutes, you can [support it](/guide/support).

_Alex_
