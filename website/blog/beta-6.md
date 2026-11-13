---
title: "Beta 6: alerts that reach you, a Tart panic fix, and one engine per Mac"
description: The sixth public beta of kinhin, the mindful CI for your Mac. What is new in beta 6, what changes when you upgrade, what has been run, what has not, and where I need your help.
sidebar: false
aside: false
---

# Beta 6: alerts that reach you, a Tart panic fix, and one engine per Mac

_Friday, November 13, 2026 · Alex Rabin_

**kinhin** watches your CI queue and, for each queued job, starts a fresh VM or container on your Apple Silicon Mac,
registers a one-job runner, lets it run, then deletes it. By default nothing idles and nothing is left over; the exceptions are runners you keep with `min_idle` and the Docker Hub cache. It is free, open source
(Apache-2.0), and sends no telemetry unless you point it at your own OpenTelemetry server.

Beta 6 is a reliability release. It adds outbound alerts, fixes a kernel panic that hit a Mac running eight Tart VMs, makes
sure only one engine scales a host's fleet, and fixes a demand bug on GitHub. It has no breaking change. The
Buildkite, Azure Pipelines and Bitbucket Pipelines work did not make this beta and moves to beta 7. This post covers what is
new, what to do when you upgrade, what has been run, and what has not.

## What is new

### Alerts that reach you

The macOS notification only helps when the menu bar app is open and you are at the Mac. With `alerts:` enabled, the daemon
also POSTs a webhook when a fleet problem is raised and when it clears, so a headless host still reaches you.

```yaml
alerts:
  enabled: true
  webhook:
    url: https://ntfy.sh/my-kinhin-topic
    format: ntfy
```

- Formats are generic JSON, Slack, Discord and ntfy. A paging service that accepts a webhook works through `generic`.
- A problem is sent once, and again only after `cooldown_seconds` while it stays raised. `min_severity: critical` skips the
  engine's own retries.
- A bearer token lives in the Keychain (`webhook.headers_keychain`), never in `config.yaml`. The URL must be `https`, except
  for localhost.
- An alert that could not be delivered is retried a minute later. A dead endpoint is logged and never stops the fleet.
- If no forge's token verifies and the fleet cannot start at all, the daemon sends one `startup` alert.

Alerts are off until you configure them. See [Alerts](https://github.com/RabinApps/kinhin/blob/main/docs/alerts.md).

### A fix for a Tart kernel panic

On macOS 27.2, every `tart list` probes each VM's disk image, and that leaks kernel APFS objects. The daemon listed VMs
back to back, and a Mac with eight Tart VMs exhausted the kernel zone map and panicked after about 41 hours. Thanks to
[@jonbeckman](https://github.com/jonbeckman) for the fix.

Now every caller in a process shares one listing, a finished listing serves for 10 seconds, and kinhin's own clone, start,
stop and delete refresh it. This lowers how often kinhin lists. I have not yet run it for 41 hours, so I am not claiming
the panic is gone for good (see below).

### One engine per host

The daemon, the menu bar app and `kinhin start` can each run a fleet engine, and two engines on one Mac would each keep their
own store and delete the other's instances as orphans. All three now take the host's engine lock. An engine the lock
refuses raises a `startup` alert and leaves the owner's instances alone. When a config change replaces the engine, the old
one now stops its listeners, which used to keep retrying against a freed engine and holding sessions.

### Queued jobs inside a running workflow

GitHub marks a workflow run `in_progress` as soon as any of its jobs starts, while sibling jobs still wait for a runner. kinhin
only looked at fully queued runs, so those siblings never produced demand and waited until something else started a runner.
Queued jobs in in-progress runs now count, and the per-poll cap on runs inspected is split between queued and in-progress
runs so a backlog of unrelated runs cannot hide them. Cancel and skip still touch only fully queued runs, so they cannot
kill a running job.

### Under the hood

The build now fails on compiler warnings, and the dependencies (Swift packages, npm, GitHub Actions) are bumped.

## Upgrading

There is no breaking change, and no config change is needed. Alerts stay off until you add `alerts:`.

- Update from beta 5 in the app, or install over it when no jobs are running. Updating restarts the daemon onto the new build
  and **interrupts its running jobs**, so update when the fleet is idle.
- If the app or `kinhin start` reports that another engine already owns the host, that is the new lock working: stop the
  other one instead of running two.

## What has been run

**Run** means it was executed for this release. **Not yet** means it has not been, and I am not claiming it.

- **Run:** the unit suite (no VMs or network) and the repository's release checks, on the release preparation commit.
- **Run:** alerts against a local `127.0.0.1` listener with a real debug-build daemon: `kinhin alerts test` delivered one message
  (exit 4 when the endpoint refused it), a fleet that could not start sent one `startup` alert, and a dead endpoint left the
  daemon running. The Slack format was the one sent. A raised-then-cleared problem was not run live.
- **Not yet:** alerts delivered to a real Slack, Discord or ntfy endpoint.
- **Not yet:** the Tart listing fix on a Mac with eight VMs over many hours.
- **Not yet:** two engines racing on a live host, including a config reload under load.
- **Not yet:** a queued sibling job inside an in-progress run on a live GitHub repository.
- **Run:** ThreadSanitizer (`scripts/tsan.sh`) on `develop` after the release preparation commit: no reports.
- **Not yet:** an upgrade from beta 5 with real state, or the in-app update from beta 5.
- **Not yet:** the end-to-end suite on this release. It runs only in CI, and its dedicated Mac is not registered yet.
- **Not yet:** the Buildkite, Azure Pipelines and Bitbucket Pipelines lanes. They did not make beta 6 and move to beta 7.
  Azure stays experimental, Buildkite and Bitbucket stay planned, and GitHub, Gitea, Forgejo and GitLab CE remain the
  supported forges.
- **Not yet:** a long-running soak test.

## Try it

The release is published on [GitHub](https://github.com/RabinApps/kinhin/releases/tag/v0.0.1-beta-6). Install it with:

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

You need an Apple Silicon Mac on macOS 15 or newer with about 60 GB of free disk and an access token for your forge. The
[Quick start](/guide/quick-start) goes from install to a running fleet.

## Where I need help

1. **Alerts.** Point `alerts:` at Slack, Discord, ntfy or your pager, break something on purpose (an expired token works), and
   tell me whether the message arrived once, and whether the resolved message followed.
2. **Big Tart fleets.** If you run many Tart VMs on macOS 27, tell me how long a host stays up, and whether `tart list`
   still shows up in the log in bursts.
3. **Upgrades.** Going from beta 5, tell me whether anything was lost or the daemon failed to start.
4. **Queued sibling jobs.** If a workflow with `needs:` or a matrix used to leave jobs waiting while one ran, tell me whether
   they start now.
5. **Real projects on the supported forges, and real Azure DevOps builds.**

One real report is valuable, including when it fails. Open a
[forge or runtime report](https://github.com/RabinApps/kinhin/issues/new/choose) and attach the output of
`kinhin doctor --bundle` after a glance through it, since it is redacted but not perfect.

## Thank you

Thank you for installing the betas and reporting what you find, and to the contributors whose pull requests are in this release.
kinhin is free and Apache-2.0. If it saves you CI minutes, you can [support it](/guide/support).

_Alex_
