---
title: "Beta 7: a redesigned app, storage on any volume, and several alert webhooks"
description: The seventh public beta of kinhin, the mindful CI for your Mac. What is new in beta 7, what changes when you upgrade, what has been run, what has not, and where I need your help.
sidebar: false
aside: false
---

# Beta 7: a redesigned app, storage on any volume, and several alert webhooks

_Wednesday, November 18, 2026 · Alex Rabin_

**kinhin** watches your CI queue and, for each queued job, starts a fresh VM or container on your Apple Silicon Mac,
registers a one-job runner, lets it run, then deletes it. By default nothing idles and nothing is left over; the exceptions are runners you keep with `min_idle` and the Docker Hub cache. It is free, open source
(Apache-2.0), and sends no telemetry unless you point it at your own OpenTelemetry server.

Beta 7 redesigns the desktop app and gives you control over where kinhin keeps its data. It adds an on/off switch for pools,
several alert webhooks, an opt-in Docker build cache, and `min_idle` floors that apply on a config reload. It has no
breaking change. The Buildkite, Azure Pipelines and Bitbucket Pipelines work did not make this beta either and moves to
beta 8. This post covers what is new, what to do when you upgrade, what has been run, and what has not.

## What is new

### A redesigned app

The window is one sidebar: Fleet, Runtimes, Accounts, Toolchains, Diagnostics and Settings, with **Support kinhin** in the
footer. Logs, Diagnostics, Benchmarks and Containers are panes of Diagnostics, whose Health tab has a **Re-check** button
and shows storage and Docker Hub cache health. The Runtimes page shows fleet capacity, the split, a card per runtime and the
routes in one place, with a pinned Apply bar that checks every **Keep idle** floor before it applies. See
[the app](https://github.com/RabinApps/kinhin/blob/main/docs/app.md).

### Storage on another volume

`tart_home`, `container_app_root`, `registry_cache_path` and `toolchain_cache_path` move Tart's home, Apple container's app
root, the Docker Hub cache and the toolchain cache to another disk. kinhin checks before any start that the volume is mounted
with ownership enabled, and never falls back to the internal disk. `kinhin doctor` reports each path, and where Apple's
`container` came from, since Apple's signed installer is the one to use with external storage. See
[Storage on another volume](/guide/config#storage-on-another-volume).

### Pools you can switch off

`enabled: false` on `container:`, a pool or `docker:`, and `runtimes.tart.enabled: false`, keep a pool's settings but take it
out of routing, scheduling and the Fleet page. Running instances drain. Every `min_idle` floor now also applies when you
reload the config, without restarting the engine.

### Several alert webhooks

`alerts.webhooks:` is a list of named webhooks, each with its own `events`, `min_severity` and `notify_on_resolve`. The old
single `webhook:` still works and is read as a webhook named `default`. `kinhin alerts test --webhook NAME` tests one, and
`kinhin doctor` reports each webhook's token. See
[Alerts](https://github.com/RabinApps/kinhin/blob/main/docs/alerts.md).

### Docker build cache, and a sturdier Docker Hub cache

`docker: { build_cache: true }` keeps each Docker runner's images and build cache between jobs, in a volume of its own per
runner. It is off by default and meant for pools whose jobs you trust alike. The Docker Hub cache has a configurable TTL
(`container.registry_cache_ttl_hours`), and kinhin now deletes broken entries so a pull no longer fails with
`unexpected EOF`; `kinhin doctor` reports the cache as unhealthy while any remain.

## Upgrading

There is no breaking change, and no config change is needed. Alerts, the build cache and the storage paths keep their old
behavior until you set them.

- Update from beta 6 in the app, or install over it when no jobs are running. Updating restarts the daemon onto the new build
  and **interrupts its running jobs**, so update when the fleet is idle.
- The app's tabs are gone: if you looked for Logs or Benchmarks, they are now panes of Diagnostics.

## What has been run

**Run** means it was executed for this release. **Not yet** means it has not been, and I am not claiming it.

- **Not yet:** the unit suite and the repository's release checks on the release preparation commit.
- **Not yet:** ThreadSanitizer (`scripts/tsan.sh`) after the release preparation commit.
- **Not yet:** storage on an external volume with a real Tart and Apple container install, including a volume mounted without ownership.
- **Not yet:** several webhooks delivered to real Slack, Discord or ntfy endpoints.
- **Not yet:** the Docker build cache across jobs on a live fleet.
- **Not yet:** an upgrade from beta 6 with real state, or the in-app update from beta 6.
- **Not yet:** the end-to-end suite on this release. It runs only in CI, and its dedicated Mac is not registered yet.
- **Not yet:** the Buildkite, Azure Pipelines and Bitbucket Pipelines lanes. They did not make beta 7 and move to beta 8.
  Azure stays experimental, Buildkite and Bitbucket stay planned, and GitHub, Gitea, Forgejo and GitLab CE remain the
  supported forges.
- **Not yet:** a long-running soak test.

## Try it

The release is published on [GitHub](https://github.com/RabinApps/kinhin/releases/tag/v0.0.1-beta-7). Install it with:

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

You need an Apple Silicon Mac on macOS 15 or newer with about 60 GB of free disk and an access token for your forge. The
[Quick start](/guide/quick-start) goes from install to a running fleet.

## Where I need help

1. **The new app.** Use it for a day and tell me what you could not find or what felt slower than the tabs.
2. **External storage.** Point `tart_home` or `container_app_root` at an external disk and tell me whether the mount check
   caught what it should, and whether anything fell back to the internal disk.
3. **Alert webhooks.** Configure two webhooks with different `events`, and tell me whether each got only its own.
4. **Upgrades.** Going from beta 6, tell me whether anything was lost or the daemon failed to start.
5. **Real projects on the supported forges.**

One real report is valuable, including when it fails. Open a
[forge or runtime report](https://github.com/RabinApps/kinhin/issues/new/choose) and attach the output of
`kinhin doctor --bundle` after a glance through it, since it is redacted but not perfect.

## Thank you

Thank you for installing the betas and reporting what you find, and to the contributors whose pull requests are in this release.
kinhin is free and Apache-2.0. If it saves you CI minutes, you can [support it](/guide/support).

_Alex_
