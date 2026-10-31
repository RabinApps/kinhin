---
title: "Beta 3: updates that install themselves, restarts that leave your jobs alone, and seven new languages"
description: The third public beta of kinhin, the mindful CI for your Mac. What is new in beta 3, what has been run, what has not, and where I need your help.
sidebar: false
aside: false
---

# Beta 3: updates that install themselves, restarts that leave your jobs alone, and seven new languages

_Saturday, October 24, 2026 · Alex Rabin_

**kinhin** watches your CI queue and, for each queued job, starts a fresh VM or container on your Apple Silicon Mac,
registers a one-job runner, lets it run, then deletes it. Nothing idles and nothing is left over. It is free, open source
(Apache-2.0), and sends no telemetry.

Beta 3 keeps a promise from the beta 2 post, makes the app update itself, and adds a few things for people who make videos
or run their own models. This post covers what is new, what has been run, and what has not.

## Keeping a promise: restarts

The beta 2 post carried a correction: on beta 2, restarting kinhin re-attached running VMs and then registered their runners
again, which could disrupt a job already running on one. Beta 3 fixes that.

- A restart no longer registers a VM again while its runner is still on the forge. A runner the forge still has is watched. A VM
  with no runner is registered as normal.
- A VM whose forge cannot be asked is held, shown by an `adoption` alert, until it can be. A VM whose account has no forge
  attached is held the same way and removed after one hour. A VM whose account was removed from the config is released at once.
- A classic container runner is registered again after a host reboot or `container system stop`, when the forge no longer has it.
- Registration stops a leftover agent without `pkill`, and fails if it survives.

[Restarts](https://github.com/RabinApps/kinhin/blob/main/docs/scaling.md#restarts) explains each rule.
I tested this live on 2026-10-24: I upgraded a Mac with real state from beta 2, and restarted kinhin while a job was running. The job was left alone.

## What is new

### An updater that installs itself

The app now updates through [Sparkle](https://sparkle-project.org). It downloads the new release, checks its EdDSA signature,
replaces the running app and relaunches. It checks once a day, and Settings → App shows **Install Update…** when one is
waiting. After an upgrade, the app restarts a daemon still running the previous build, which **interrupts that daemon's jobs**,
so update when the fleet is idle.

Beta 2 and earlier open the DMG for a manual drag into Applications, and beta 2 published no update feed, so you update by hand
**once**, from beta 2 to beta 3. Updates after that install automatically.
The in-app install has not been exercised against a published release yet. That needs a release that already contains the
updater, so the first real test is beta 3 to the next release.

### Healing with your own models

The healing agent can ask [Ollama](https://ollama.com) instead of Apple Intelligence: `healing: {ai: ollama, ollama: {model: …}}`.
An optional `fast_model` is asked first, and the larger model answers when it is not confident. Traffic goes to this Mac by
default. Any other host must be `https`, and it then receives the redacted problem, the allowed fixes and the log lines. It still only chooses among
fixes that are already allowed. See [docs/healing.md](https://github.com/RabinApps/kinhin/blob/main/docs/healing.md#the-ollama-advisor).

### Videos with a camera

Videos from your repository got a director:

- A `device` or `terminal` scene's `camera` zooms and pans, `focus` spotlights part of the screen and `cursor` adds a pointer with
  click rings. Adapters can name regions of a clip, so a redesigned screen is fixed once.
- `karaoke` captions light each word as it is spoken. `transition` replaces the fade between scenes. `speed` takes eased
  segments, and a `split` scene plays two recordings side by side.
- Rebuilds reuse the voice and the framed clips, so a one-line edit no longer redoes the video. `kinhin video build --scene app,outro`
  builds a quick preview, `--watch` rebuilds on change, and every build prints how long each step took.

Nothing changes for a video that does not use them.

### Seven new languages for the app

The menu bar app now follows the macOS language in Spanish, Japanese, German, Hebrew, Arabic, Italian and French. **These are
first drafts, not reviewed by native speakers.** The CLI, its output and the docs stay English. Disclosure arrows mirror in
right-to-left languages.
I have not looked at every language in the running app, so expect truncated text or odd layout somewhere.

### Fixes

- `kinhin image digest` and the app's Pin button no longer fail with `registry answered HTTP 404` for Cirrus Labs images.
- A new VM no longer waits the whole `vm_boot_timeout` when macOS Local Network privacy blocks its port 22 probe. After 15
  seconds kinhin tries SSH anyway and logs why. The app declares a Local Network usage description.
- `kinhin doctor` no longer calls Command Line Tools outdated when they only trail macOS by a patch release.
- `kinhin auth list --json` exists, and `kinhin auth status --account NAME --json` reports only that account.
- Azure DevOps warns at start-up when the agent pool has no matching agent.

## Where the forges stand

Beta 3 was going to be the "more forges" release. It is not. Buildkite, Azure Pipelines and Bitbucket Pipelines need real
accounts and a dedicated test Mac that I have not set up, and I would rather ship what is done than claim support I have not
run. **Azure Pipelines is now labelled experimental**: one user ran smoke jobs against Azure DevOps Services, two concurrent
VMs and scale from zero, but not a real application build. **Buildkite and Bitbucket Pipelines are still planned.** Test fixtures for
all three are written and have not run. This work moves to beta 5 (it did not make [beta 4](/blog/beta-4) either). GitHub, Gitea, Forgejo and GitLab CE remain the supported
forges.

## What has been run

**Run** means it was executed for this release. **Not yet** means it has not been, and I am not claiming it.

- **Run:** the unit suite (3,453 tests, no VMs or network) and the release build's own check, on the release commit.
- **Run:** the ThreadSanitizer run on the release commit, with no reports.
- **Run:** an upgrade from beta 2 on a Mac with real state (nothing lost), and a restart under a real running job, which was left alone. One Mac, one pass.
- **Not yet:** the end-to-end suite on this release. It runs only in CI, and its dedicated Mac is not registered yet.
- **Not yet:** the Buildkite, Azure Pipelines and Bitbucket Pipelines lanes.
- **Not yet:** a long-running soak test.

## Try it

The release is published on [GitHub](https://github.com/RabinApps/kinhin/releases/tag/v0.0.1-beta-3). Install it with:

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

You need an Apple Silicon Mac on macOS 15 or newer with about 60 GB of free disk, and an access token for your forge. The
[Quick start](/guide/quick-start) goes from install to a running fleet. Coming from beta 2, install over it by hand once, when no
jobs are running.

## Where I need help

1. **Restarting under load.** Restart the daemon (or reboot the Mac) while jobs run, and tell me whether any job was disturbed.
2. **Upgrading with real state.** Your fleet, project images and config, on beta 2, then beta 3. Tell me if anything was lost.
3. **The updater.** The first in-app update is from this release to the next. Tell me whether it installed and relaunched.
4. **A language that is not English.** Tell me which strings are wrong, awkward or cut off.
5. **Ollama healing and video cameras.** Send me a journal entry or a video that looks wrong.
6. **Real projects on the supported forges, and real Azure DevOps builds.**

One real report is valuable, including when it fails. Open a
[forge or runtime report](https://github.com/RabinApps/kinhin/issues/new/choose) and attach the output of
`kinhin doctor --bundle` after a glance through it, since it is redacted but not perfect.

## Thank you

kinhin is free and Apache-2.0. If it saves you CI minutes, you can [support it](/guide/support).

_Alex_
