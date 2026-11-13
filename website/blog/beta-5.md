---
title: "Beta 5: Apple container pools, Docker inside containers, and x86_64 runners"
description: The fifth public beta of kinhin, the mindful CI for your Mac. What is new in beta 5, what changes when you upgrade, what has been run, what has not, and where I need your help.
sidebar: false
aside: false
---

# Beta 5: Apple container pools, Docker inside containers, and x86_64 runners

_Tuesday, November 3, 2026 · Alex Rabin_

**kinhin** watches your CI queue and, for each queued job, starts a fresh VM or container on your Apple Silicon Mac,
registers a one-job runner, lets it run, then deletes it. By default nothing idles and nothing is left over; the exceptions are runners you keep with `min_idle` and the Docker Hub cache described below. It is free, open source
(Apache-2.0), and sends no telemetry unless you point it at your own OpenTelemetry server.

Beta 5 is mostly about Linux runners on Apple container. You can now split them into named pools, run Docker inside them,
run x86_64 images under Rosetta, and keep idle runners registered. It has no breaking change. This post covers what is new,
what to do when you upgrade, what has been run, and what has not.

## What is new

### Named container pools

`container.pools:` splits Apple container into pools. Each pool has its own image, `cpus`, `memory_gb`, labels, `min_idle`,
`docker`, `flags` and an optional `max:`; the `container:` section's own keys are the defaults. A job goes to the pool whose
labels it carries, and `runs-on: [..., kinhin-container-NAME]` targets one pool. Pools share Apple container's CPU and memory,
and a runner starts only when its pool's size fits what is left.

- `kinhin image prepare --container --pool NAME` (or `--all`) bakes a pool's image, and `kinhin workflow route --pool NAME`
  shows where a job would go.
- A pool whose image is not built is left out, so its jobs wait instead of holding every pool in spawn backoff.
- `kinhin doctor` lists each pool, its image and whether it fits.
- The app shows and edits pools: **Advanced → Routing** has a card per pool and **Add Container Pool…**, **Edit…** and
  **Remove**, and the Fleet tab shows each container runner's pool.
- Telemetry labels Apple container series with `kinhin.container.pool` and reports an unbuilt pool as `kinhin.spawn.held`.

Without `pools:`, nothing changes. See [Several container pools](https://github.com/RabinApps/kinhin/blob/main/docs/runtimes.md#several-container-pools).

### Docker inside container runners

`container.docker: true` starts `dockerd` in each Apple container runner before it registers, so jobs can `docker run`,
`docker build` and `docker compose`. `kinhin image prepare --container` installs Docker when the base image lacks it, and
`container.flags:` passes extra arguments to `container run`.

The container gets every Linux capability to run Docker, so keep this on pools you trust the workflows of.
See [Docker inside container runners](https://github.com/RabinApps/kinhin/blob/main/docs/runtimes.md#docker-inside-container-runners).

### A Docker Hub cache

With `docker: true`, Docker Hub pulls go through a pull-through cache that kinhin runs: one Apple container,
`registry-cache-kinhin`, started by the first Docker runner. A job's `services:` and Docker actions are pulled from Docker Hub
once per Mac instead of once per job, under one anonymous pull limit. If the cache cannot be reached, the runner registers
anyway and pulls from Docker Hub. It is on by default; `docker: { cache: false }` turns it off. `kinhin doctor` reports it.
See [Docker Hub cache](https://github.com/RabinApps/kinhin/blob/main/docs/runtimes.md#docker-hub-cache).

### x86_64 runners under Rosetta

`container.platform: linux/amd64`, on the section or on one pool, runs x86_64 Linux runners on Apple container. The image is
baked as amd64, the runner registers with `x64` instead of `arm64`, and a job that asks for `x64` goes to an amd64 pool.
Docker jobs on an amd64 runner build through a buildx builder, because dockerd's built-in builder cannot run a build step
under Rosetta. See [x86-64 container runners](https://github.com/RabinApps/kinhin/blob/main/docs/runtimes.md#x86-64-amd64-container-runners).

### Idle runners that stay registered

`min_idle` keeps a number of registered, idle runners for each pool and each Tart image, so the forge's runner list always
shows a free runner for every label set the fleet serves. Set it on an `images:` entry, on `container:` or `docker:`, or use
`image_min_idle:` for the top-level `image:`. A busy runner does not count, so a replacement starts as soon as an idle runner
takes a job. Queued jobs get slots first, and floors fill the room left under your caps and Apple's limit of two macOS VMs.
`min_runners` is unchanged. See [Idle runners per pool and image](https://github.com/RabinApps/kinhin/blob/main/docs/scaling.md#idle-runners-per-pool-and-image).

### Smaller container images

`kinhin image prepare --container` now bakes as layers on the base image instead of exporting a scratch container's whole
filesystem. Disk use follows what kinhin adds, not the size of the base: a 31 GB base used to need about 250 GB free. The
`--container-image` flag is checked like the config's `base_image`, and `--clean-builder` deletes the builder after a bake.

### Fixes

- **The menu bar app** cleared every image's `warm_pool`, and dropped a section's `fleet_labels:`, when you edited a named image
  or a base image. Both are kept now.
- **A third Tart VM** could start beside two warm ones when the Tart budget partition is 2, Apple's limit for macOS VMs. Warm
  VMs are now evicted to keep the partition.
- **`fleet_labels: false`** on `container:` or `docker:` was ignored by the running fleet and the Routing tab. They now agree
  with `kinhin workflow route`.
- **`min_runners`** is one count for the whole fleet. The scaling page said it was per pool, and now says what it does.

## Upgrading

There is no breaking change, and no config change is needed.

- The next `kinhin image prepare --container` bakes as layers. The baked image keeps the base's `ENV` and `WORKDIR`, runs as
  `USER root` and has no `ENTRYPOINT`. The builder keeps a build cache (about 100 GB after a 31 GB base). Run
  `container builder stop && container builder delete` once to reclaim an old bake's cache, or pass `--clean-builder`.
- With `container.docker: true`, pulls go through the Docker Hub cache unless you set `docker: { cache: false }`.

## What has been run

**Run** means it was executed for this release. **Not yet** means it has not been, and I am not claiming it.

- **Run:** the unit suite (no VMs or network) and the repository's release checks, locally on the release preparation commit.
- **Not yet:** a live fleet with named container pools, including `kinhin-container-NAME` routing and the app's pool editor.
- **Not yet:** Docker inside a container runner, and the Docker Hub cache, on a live job.
- **Not yet:** an x86_64 runner under Rosetta, including a Docker build on it.
- **Not yet:** `min_idle` against a real forge's runner list.
- **Not yet:** ThreadSanitizer on the release commit.
- **Not yet:** an upgrade from beta 4 with real state, or the in-app update from beta 4.
- **Not yet:** the end-to-end suite on this release. It runs only in CI, and its dedicated Mac is not registered yet.
- **Not yet:** the Buildkite, Azure Pipelines and Bitbucket Pipelines lanes. They did not make beta 5 and move to beta 7.
  Azure stays experimental, Buildkite and Bitbucket stay planned, and GitHub, Gitea, Forgejo and GitLab CE remain the
  supported forges.
- **Not yet:** a long-running soak test.

## Try it

The release is published on [GitHub](https://github.com/RabinApps/kinhin/releases/tag/v0.0.1-beta-5). Install it with:

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

You need an Apple Silicon Mac on macOS 15 or newer with about 60 GB of free disk (a baseline for running; `image prepare --container` on a large base image needs much more, and its builder cache can reach about 100 GB after a 31 GB base), and an access token for your forge. The
[Quick start](/guide/quick-start) goes from install to a running fleet. Coming from beta 4, the app can update itself, or you
can install over it when no jobs are running.

## Where I need help

1. **Container pools.** Split your Linux jobs across two pools and tell me whether each job lands where you expect, and whether
   the app's pool editor does what it says.
2. **Docker in a container.** Run a `docker build` or a job with `services:` and tell me whether it worked, and whether the
   Docker Hub cache was used.
3. **x86_64 runners.** Run a job that needs `x64` and tell me what breaks under Rosetta.
4. **`min_idle`.** Set a floor and tell me whether the forge's runner list shows what you expect.
5. **Lighter bakes.** Re-bake a large base image and tell me how much disk it used.
6. **Real projects on the supported forges, and real Azure DevOps builds.**

One real report is valuable, including when it fails. Open a
[forge or runtime report](https://github.com/RabinApps/kinhin/issues/new/choose) and attach the output of
`kinhin doctor --bundle` after a glance through it, since it is redacted but not perfect.

## Thank you

Thank you for installing the betas and reporting what you find, and to the contributors whose pull requests are in this release.
kinhin is free and Apache-2.0. If it saves you CI minutes, you can [support it](/guide/support).

_Alex_
