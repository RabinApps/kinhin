<!--
DRAFT. Marker forms: GATE:Tn start ... GATE:Tn end (keep on pass) and
FALLBACK:Tn start ... FALLBACK:Tn end (keep on fail). Resolve every
TODO(verify:Tn) and [MEASURE: ...]. See beta-4-launch-checklist.md.
Remove this comment before publishing.
-->
---
title: "Beta 4: telemetry you opt into, macOS 27 images, and fixes from your installs"
description: The fourth public beta of kinhin, the mindful CI for your Mac. What is new in beta 4, what changes when you upgrade, what has been run, what has not, and where I need your help.
sidebar: false
aside: false
---

# Beta 4: telemetry you opt into, macOS 27 images, and fixes from your installs

_TODO(verify:Tdate): Weekday, Month D, 2026 · Alex Rabin_

<figure>
  <video controls playsinline preload="metadata" :poster="'/beta-4-poster.png'" style="width: 100%; border-radius: 8px">
    <source :src="'/beta-4.webm'" type="video/webm" />
    <source :src="'/beta-4.mp4'" type="video/mp4" />
    <a href="/beta-4.mp4">Watch the beta 4 video</a>
  </video>
</figure>

**kinhin** watches your CI queue and, for each queued job, starts a fresh VM or container on your Apple Silicon Mac,
registers a one-job runner, lets it run, then deletes it. Nothing idles and nothing is left over. It is free, open source
(Apache-2.0), and sends no telemetry unless you point it at your own OpenTelemetry server.

Beta 4 adds that opt-in telemetry, the macOS 27 base images, and a round of fixes for problems people hit when they installed
beta 3. It also has one breaking change for Linux runners. This post covers what is new, what to do when you upgrade, what has
been run, and what has not.

## What is new

### Telemetry you opt into

kinhin can now export metrics, traces and logs about the fleet and the jobs it runs. It is **off by default**. Until you set
`telemetry.enabled: true`, kinhin starts no exporter, opens no port and sends nothing anywhere. When you turn it on, the data
goes to a collector you run, such as Grafana Alloy or the OpenTelemetry Collector. It never goes to me.

- Metrics cover workers by pool and state, queue depth and age, fleet size, the warm pool, boot and registration timings, jobs
  picked up and completed, forge request counts and rate limits, and classified errors. No VM, job or run ID is a metric label.
- Each instance gets one trace. The job result and step spans come from the forge when it can say, and read `unknown` otherwise.
- Logs go over OTLP too, and `log_format: json` writes structured local logs.
- `prometheus_listen` serves the metrics on a local Prometheus `/metrics` endpoint, bound to `127.0.0.1` unless you say otherwise.
- `kinhin telemetry status` shows what the daemon sends where, and whether exports are failing.
- `kinhin config reload` makes the running daemon re-read your config. Telemetry and routing changes apply in place, and an
  invalid file is refused before it reaches the daemon.
- The app has a Telemetry card under Advanced → App that shows the export status and switches it on or off.
- A Grafana dashboard and alert rules are in the repository, with a ready Alloy snippet.

Two honest limits. The OpenTelemetry Swift SDK marks traces stable, but metrics and logs as still in development upstream, so
**treat this as beta** and expect a rough edge there. And passing trace context into your workflow steps is not part of this
release. Setup, the metric list and the privacy notes are in the [telemetry guide](https://github.com/RabinApps/kinhin/blob/main/docs/telemetry.md).

<!-- GATE:T10 start -->
I ran it against [MEASURE: collector, e.g. Alloy to Grafana Cloud, and the Prometheus endpoint] on [MEASURE: date], with
[MEASURE: what ran]. [MEASURE: what the dashboard and alert rules showed, and what did not render].
<!-- GATE:T10 end -->
<!-- FALLBACK:T10 start -->
This is covered by unit tests and the end-to-end cases written for it. I have not yet exported from a live fleet to a real
collector, so the dashboard and the alert rules are untested against real data.
<!-- FALLBACK:T10 end -->

### macOS 27 base images

The macOS 27 "Golden Gate" images (`macos-golden-gate-base`, `-vanilla` and `-xcode`) are in the base-image picker. A
`ghcr.io/cirruslabs/macos-*` reference pinned by `@sha256:` is accepted too, because the pin names exact bits and stays
servable after its tag is retired. When kinhin refuses a base image, it now says what it would accept, including
`kinhin image digest` for printing a pin. See [Choosing the base image](https://github.com/RabinApps/kinhin/blob/main/docs/runtimes.md#choosing-the-base-image).
<!-- GATE:T11 start -->
I booted a Golden Gate base and ran [MEASURE: what ran] on [MEASURE: date].
<!-- GATE:T11 end -->
<!-- FALLBACK:T11 start -->
I have not yet booted a Golden Gate image and run a job on it. The picker and the digest handling are covered by unit tests.
<!-- FALLBACK:T11 end -->

### Fixes from install feedback

- **`kinhin daemon install`** wrote whatever path it was run by into the LaunchAgent. A bare `kinhin` resolved through `PATH`
  became `<cwd>/kinhin`, which launchd could not run at login. The path now comes from the running binary, and the install checks
  that the agent actually started. A daemon that exits at once is reported as a failure.
- **`warm_pool: 1`** could keep two VMs, because a pooled VM still cloning or booting was invisible to the scale plan. In-flight
  pooled VMs now count toward the target and the caps.
- **`vm.cpu` and `vm.memory_gb`** were ignored on Tart. They are now set on the clone before its first boot, and a failed
  `tart set` fails the spawn instead of booting an unconstrained VM.
- **`image delete` and `image prune`** stopped at the first image that could not be deleted. They now continue, report every
  failure at the end, and keep the record of an image that failed so you can try again.
- **The budget bar** in `kinhin runtimes` printed only edge values, because it rounded at the wrong step.
- **Multi-runner VMs** show every running job in the fleet view, not just one.
- **Timers** no longer keep ticking on a finished job.

There is also `kinhin config validate FILE`, which checks a named file instead of this Mac's default config. It helps before you
point a fleet at a file, and in CI.

## Upgrading

**This is a breaking change.** Apple-container and Docker runners no longer advertise the `macos` label. Their guests run Linux,
and a macOS job started there would never finish. If a workflow has `runs-on: […, macos]` and means a Linux runtime, change it
to the marker label: `kinhin-container` or `kinhin-docker`. If a Linux pool should not inherit the fleet's labels at all, set
`fleet_labels: false` under `container:` or `docker:`. The pool then registers with the marker
and that section's own labels alone. [Runtimes](https://github.com/RabinApps/kinhin/blob/main/docs/runtimes.md) has the details.

Also:

- If the daemon does not start after the upgrade, re-run `kinhin daemon install`.
- The default `image:` can now carry runner labels through `image_labels:`. A Linux default base keeps macOS jobs off its runners.
- **The updater.** Beta 3 introduced in-app updates through Sparkle, and beta 3 to beta 4 is the first time a published release
  updates a published release. When the app restarts the daemon onto the new build, **it interrupts that daemon's running jobs**,
  so update when the fleet is idle.
<!-- GATE:T8 start -->
I installed this update in the app from a [MEASURE: signed rehearsal build / published beta 3]. [MEASURE: what happened]
<!-- GATE:T8 end -->
<!-- FALLBACK:T8 start -->
I have not yet watched a real beta 3 install this update itself. If it fails, install over it by hand and tell me.
<!-- FALLBACK:T8 end -->

## What has been run

**Run** means it was executed for this release. **Not yet** means it has not been, and I am not claiming it.

<!-- GATE:T1 start -->
- **Run:** the unit suite ([MEASURE: test count] tests, no VMs or network) and the release build's own check, on the release commit.
<!-- GATE:T1 end -->
<!-- GATE:T4 start -->
- **Run:** the ThreadSanitizer run on the release commit, with no reports.
<!-- GATE:T4 end -->
<!-- FALLBACK:T4 start -->
- **Not yet:** ThreadSanitizer on the release commit.
<!-- FALLBACK:T4 end -->
<!-- GATE:T6 start -->
- **Run:** an upgrade from beta 3 on a Mac with real state, [MEASURE: date], with nothing lost and
  `kinhin daemon install` starting the daemon after a reboot. [MEASURE: what else]
<!-- GATE:T6 end -->
<!-- FALLBACK:T6 start -->
- **Not yet:** an upgrade from beta 3 with real state, and the daemon starting at login from the new LaunchAgent path.
<!-- FALLBACK:T6 end -->
<!-- GATE:T12 start -->
- **Run:** a job with `runs-on: kinhin-container` [MEASURE: and kinhin-docker] on a live Linux runner, and a `macos` job that
  stayed off it. [MEASURE: date, runtime]
<!-- GATE:T12 end -->
<!-- FALLBACK:T12 start -->
- **Not yet:** a live job on a Linux runner under the new labels. The label rules are covered by unit tests.
<!-- FALLBACK:T12 end -->
<!-- GATE:T13 start -->
- **Run:** `vm.cpu` and `vm.memory_gb` on a live Tart clone, and `warm_pool: 1` holding one VM. [MEASURE: values seen]
<!-- GATE:T13 end -->
<!-- FALLBACK:T13 start -->
- **Not yet:** `vm.cpu`, `vm.memory_gb` and `warm_pool: 1` on a live Tart host. They are covered by unit tests.
<!-- FALLBACK:T13 end -->
- **Not yet:** the end-to-end suite on this release. It runs only in CI, and its dedicated Mac is not registered yet.
- **Not yet:** the Buildkite, Azure Pipelines and Bitbucket Pipelines lanes. Azure stays experimental, Buildkite and
  Bitbucket stay planned, and GitHub, Gitea, Forgejo and GitLab CE remain the supported forges.
- **Not yet:** a long-running soak test.

## Try it

The release is published on [GitHub](https://github.com/RabinApps/kinhin/releases/tag/v0.0.1-beta-4). Install it with:

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

You need an Apple Silicon Mac on macOS 15 or newer with about 60 GB of free disk, and an access token for your forge. The
[Quick start](/guide/quick-start) goes from install to a running fleet. Coming from beta 3, the app can update itself, or you
can install over it when no jobs are running.

## Where I need help

1. **The first real in-app update.** Update from beta 3 to beta 4 in the app and tell me whether it downloaded, installed and
   relaunched.
2. **Telemetry on a real collector.** Point it at yours, import the dashboard, load the alert rules, and tell me what is wrong
   or missing. Send the output of `kinhin telemetry status` if exports fail.
3. **The label change.** Move a Linux workflow to `kinhin-container` or `kinhin-docker` and tell me whether anything still
   lands on the wrong runner.
4. **A fresh install.** Run `kinhin daemon install` from a clean shell and reboot. Tell me whether the daemon came back.
5. **macOS 27 images.** Tell me what you build on Golden Gate and what breaks.
6. **Real projects on the supported forges, and real Azure DevOps builds.**

One real report is valuable, including when it fails. Open a
[forge or runtime report](https://github.com/RabinApps/kinhin/issues/new/choose) and attach the output of
`kinhin doctor --bundle` after a glance through it, since it is redacted but not perfect.

## Thank you

Several of these fixes came straight from your install reports. kinhin is free and Apache-2.0. If it saves you CI minutes, you
can [support it](/guide/support).

_Alex_
