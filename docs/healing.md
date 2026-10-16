# The healing agent

kinhin watches its own fleet for problems and fixes the ones it safely can. A warm VM that was deleted behind its
back, a toolchain cache filling the disk, an account that dropped off for a minute: these are fixed on their own.
Anything destructive or slow (pruning images, reinstalling a runtime) waits for you to approve it. Anything only you
can do (a new token, an image bake) is shown with the exact command.

In a build that includes it, on a Mac with Apple Intelligence (macOS 26 or later), an on-device model is also asked
about problems no rule covers. It may only pick from the fixes kinhin allows for that problem, and it can never make a
fix run that would otherwise wait for you. Nothing leaves your Mac.

[← Back to README](../README.md) · [How scaling works](scaling.md) · [Troubleshooting](../website/guide/troubleshooting.md)

## What it does on its own, and what it asks first

Every fix has a fixed tier: **automatic** (runs on its own), **approval** (waits for you) or **yours** (only you can do
it; kinhin says how). The rules, the advisor and the config can lower what runs on its own, never raise it.

| Problem | Fix | Tier |
| ------- | --- | ---- |
| A warm VM (or any instance nothing is driving) was stopped or deleted outside kinhin | Remove its record and leftovers; a replacement starts if work is waiting (the engine's own sweep, every 2 minutes, with healing on or off; journaled when healing is on) | Automatic |
| Spawns are held on disk pressure | Prune the toolchain cache by its `toolchain_cache:` policy, and surplus per-project images (only when `auto_prune` is on) | Automatic |
| ...and the disk is still full after that (or `auto_prune` is off) | Prune unused images, as `kinhin image prune --yes` does | Approval |
| An account dropped off (timeout, unreachable server) for a minute | Re-attach it now instead of waiting out its backoff | Automatic |
| An account was refused (401/403, bad token) | `kinhin auth set --account NAME` | Yours |
| A token is missing or the Keychain cannot be read | `kinhin auth set` | Yours |
| The Apple container system is not running | `container system start` | Automatic |
| A runtime is missing (its setup check fails, or its runners keep failing) | Install it, as `kinhin setup repair <runtime>` does | Approval |
| Tart is killed on launch or broken | Reinstall, or roll back to the notarized build | Approval |
| An image is not prepared | `kinhin image prepare` | Yours |
| Another runtime or image setup check fails | The fix `kinhin setup status` lists | Yours |
| A teardown has kept failing for 10 minutes | Remove the instance with its runtime, then `kinhin cleanup --vms` | Yours |
| A queue unreadable for 2 minutes, a reconcile pass failing for 2 minutes, runners that keep failing on a healthy runtime | No rule: the advisor is asked if one is available, otherwise it is shown to you | Depends on the pick |

Tart setup checks (tart itself, its rollback, the base image) only count when the fleet can run Tart VMs: Tart is the
default runtime, a route names it, `images:` has entries, or `warm_pool` is set. A Docker-only fleet is never told to
install tart.

The engine's own retries keep running underneath: spawn backoff, orphan sweeps, teardown retries and forge re-attach
backoff all work with healing off. The agent adds what they do not cover, and gives every problem one place to look.

## How it decides

The agent runs in its own loop beside the scaling loop, every 30 seconds, so a slow fix or a slow model never delays
scaling. On each pass it collects the current problems from the status alerts, the instance records, the spawn backoff
and the setup checks, one entry per problem. The setup checklist runs once when the fleet starts, then again (at most
every 5 minutes) only while it reports a problem or runners keep failing to start: a healthy fleet does not re-run it.

- **It waits before acting.** An account must stay detached for a minute, a queue read or a reconcile pass must keep
  failing for 2 minutes, and a teardown for 10 minutes; a one-off failure heals by itself.
- **It tries each fix a few times.** A fix is tried at most `max_attempts` times for one problem, at least 2 minutes
  apart. A fix that ran and succeeded but left the problem in place counts as spent, and the next fix in the list is
  tried.
- **Then it escalates once.** When no fix is left (or the problem has no rule), the advisor is asked once, if one is
  available and there is anything it may pick. Otherwise the problem is shown to you. If the advisor's fix runs and the
  problem is still there after the cooldown, that is shown to you too, once.
- **It forgets what went away.** A problem that goes away closes its open entries ("went away"), and the next time it
  happens kinhin starts over with a fresh budget.

A fix that waits for approval, or a problem shown to you, stays open until you act, dismiss it, or the problem goes
away. Nothing new is tried for that problem in the meantime.

## `kinhin heal`

```bash
kinhin heal                   # policy, fixes waiting for approval, problems that need you, recent history
kinhin heal --json            # the same as a document
kinhin heal --quiet           # nothing printed; the exit code is the answer
kinhin heal approve h-8d04e7c2
kinhin heal dismiss h-8d04e7c2
```

A fleet that pruned its cache on its own and now waits to prune images:

```text
$ kinhin heal
healing: safe fixes run on their own; rules only

waiting for approval (kinhin heal approve ID):
  h-8d04e7c2  prune unused images needs approval: disk pressure: 18 GB free, a new docker instance needs 8 GB + 20 GB reserve — holding spawns

recent:
  h-5e1a90d3  succeeded 3m ago  freed 2048 MB from 37 cache entr(ies)
  h-3f9c21ab  succeeded 12m ago  removed kinhin-1760432400-a1b2; a replacement starts if work is waiting
```

Problems only you can fix are listed under `needs you (kinhin heal dismiss ID once handled):`. The history shows the
last 10 closed entries. With `healing.enabled: false` the command only says that healing is off.

`approve` starts the fix in the background and returns at once (an install can take minutes); run `kinhin heal` again
to see how it ended. `dismiss` closes a pending or shown entry and leaves that problem alone until it goes away.

`kinhin heal` talks to the daemon. With no daemon it says so and prints the history the last one left (up to 10
entries); entries that were still open read as `expired`, since nobody can act on them now. A problem that persists is
raised again when the fleet starts.

| Command | Exit code |
| ------- | --------- |
| `kinhin heal` | 0 when nothing waits on you; 1 when a fix waits for approval, a problem needs you, or no daemon runs; 4 when the daemon cannot answer (one that predates healing: restart it) |
| `kinhin heal approve ID`, `kinhin heal dismiss ID` | 0 done; 1 no daemon; 2 no ID, or an ID that is not in the journal; 4 an entry that is not waiting on you (already approved, ran or closed) |

### The JSON document

Printed with sorted keys and ISO 8601 dates. The MCP `heal_status` tool returns the same document.

| Field | Meaning |
| ----- | ------- |
| `daemon` | False when no daemon answered; `pending` and `surfaced` are then empty and `events` is the stored history |
| `enabled`, `automatic` | `healing.enabled`, and whether `healing.auto` is `safe` |
| `advisor` | The advisor consulted (`apple-intelligence`); absent when there is none |
| `pending` | Fixes waiting for approval, newest first |
| `surfaced` | Problems only you can fix, newest first |
| `events` | The whole journal, newest first (`kinhin status` carries only the open entries and the 10 newest closed ones) |
| `message` | Only when no daemon answered: why |

Each entry has an `id`, the `signal` (its `kind`, `subject` and `detail`, plus `evidence` or `setupAction` when the
engine probed), the `remediation` (`kind` and `subject`; absent when nothing fits and the problem is only shown), the
`source` (`playbook` or `advisor`), the `outcome`, a token-free `detail`, the advisor's `explanation` when it picked
the fix, and `createdAt` / `updatedAt`. Outcomes: `pending`, `running`, `succeeded`, `failed`, `surfaced`,
`dismissed`, `resolved` (the problem went away first) and `expired` (left open when the fleet stopped).

```json
{
  "automatic" : true,
  "daemon" : true,
  "enabled" : true,
  "events" : [
    {
      "createdAt" : "2026-10-14T09:20:00Z",
      "detail" : "prune unused images needs approval: disk pressure: 18 GB free, a new docker instance needs 8 GB + 20 GB reserve — holding spawns",
      "id" : "h-8d04e7c2",
      "outcome" : "pending",
      "remediation" : {
        "kind" : "prune_images"
      },
      "signal" : {
        "detail" : "disk pressure: 18 GB free, a new docker instance needs 8 GB + 20 GB reserve — holding spawns",
        "kind" : "disk_pressure"
      },
      "source" : "playbook",
      "updatedAt" : "2026-10-14T09:20:00Z"
    }
  ],
  "pending" : [
    {
      "createdAt" : "2026-10-14T09:20:00Z",
      "detail" : "prune unused images needs approval: disk pressure: 18 GB free, a new docker instance needs 8 GB + 20 GB reserve — holding spawns",
      "id" : "h-8d04e7c2",
      "outcome" : "pending",
      "remediation" : {
        "kind" : "prune_images"
      },
      "signal" : {
        "detail" : "disk pressure: 18 GB free, a new docker instance needs 8 GB + 20 GB reserve — holding spawns",
        "kind" : "disk_pressure"
      },
      "source" : "playbook",
      "updatedAt" : "2026-10-14T09:20:00Z"
    }
  ],
  "surfaced" : [

  ]
}
```

### Elsewhere

- A pending fix raises a `healing` alert in `kinhin status` ("1 fix(es) need approval — run `kinhin heal`"), which
  the app turns into a "kinhin needs attention" notification.
- The app posts "kinhin fixed a problem" each time a fix succeeds.
- The app's Diagnostics sheet has a Healing card: the policy, the fixes waiting for approval (Approve, Dismiss), the
  problems that need you (Dismiss), what is running and the last 10 closed entries. When the app runs the fleet in its
  own process instead of the daemon, this card is where healing shows.
- The MCP server's `heal_status` tool is read-only: approving a fix stays with a person.

## Fixes and what they run

Every fix goes through a code path kinhin already uses elsewhere; nothing runs a command a person or a model wrote. The
kind is what `remediation.kind` says in the journal.

| Kind | Tier | What runs |
| ---- | ---- | --------- |
| `recycle_instance` | Automatic | The engine's normal removal of one instance (record and leftovers), then the scaler is woken |
| `retry_forge_attach` | Automatic | Every detached account is re-attached now, skipping its backoff; fails if the account stays detached |
| `prune_toolchain_cache` | Automatic | The cache prune `kinhin toolchains prune` runs, with your `toolchain_cache:` policy, then derived per-project images beyond `max_project_images` or older than `max_age_days` (images in use stay) |
| `start_container_system` | Automatic | `container system start` |
| `prune_images` | Approval | The plan `kinhin image prune --yes` runs: stale records and unused local images across Tart, Apple container and Docker; images the fleet uses stay |
| `repair_runtime` | Approval | The installer `kinhin setup repair <runtime>` runs (for host, the runner agents); nothing when it is already installed |
| `repair_tart` | Approval | The first repair the tart health check lists (reinstall, or roll back to the notarized build), each command allowed 30 minutes |
| `replace_token` | Yours | Shown: `kinhin auth set --account NAME` |
| `prepare_image` | Yours | Shown: `kinhin image prepare` |
| `inspect_instance` | Yours | Shown: delete the instance with its runtime (`tart delete`, `docker rm -f` or `container delete`), then `kinhin cleanup --vms` |
| `review_setup` | Yours | Shown: run `kinhin setup status` and use the fix it lists |

## Config

```yaml
healing:
  enabled: true      # false = only the engine's own retries; nothing new is fixed or journaled
  auto: safe         # safe = automatic-tier fixes run on their own; none = every fix waits for approval
  ai: auto           # auto = ask the on-device model about problems no rule covers; off = rules only
  max_attempts: 3    # tries of one fix for one problem before it escalates (1-10)
```

Every key is optional; the values above are the defaults. Any other value is a config error (exit 3) that names the
key. Changing them rebuilds the engine (instances are kept, open entries expire and are raised again if the problem
persists).

## The on-device advisor

The advisor is Apple Intelligence through Apple's Foundation Models framework, running in the process that runs the
fleet. For a problem it is asked about, it gets:

- the problem as kinhin sees it (no tokens: every message is redacted first),
- the fixes kinhin allows for that problem's subject (a VM, an account, a runtime, the disk), minus the ones already
  spent, and
- up to 40 recent log lines about it (warnings and errors when the problem has no subject), trimmed to fit the model's
  window.

It answers in one structured generation: one of those fixes or none (the answer's schema only allows those ids),
whether it is sure, and one sentence of reasoning that the journal shows next to the entry. kinhin checks the answer again: a fix outside the list is ignored and logged, an
approval-tier fix still waits for you, and a pick the model is not sure about is only shown ("suggests …, but is not
sure"). Tokens and setup problems are never offered to the model. The answer has 20 seconds; if the model is slow or
unavailable, the problem is shown to you as if there were no advisor. Whether
the model is ready is checked again every 10 minutes.

The explanation is for reading only and can be wrong about the cause. It never drives an action.

**Requirements:** macOS 26 or later on Apple Silicon with Apple Intelligence turned on. Every kinhin build includes
the advisor; on macOS 15, or with Apple Intelligence off or its model still downloading, kinhin runs the rules only and
`kinhin heal` says "rules only".

## What healing does not do

- It never stores, reads or replaces a token, and never edits your config.
- It never runs a free-form command. The advisor can only pick from the list above; it cannot add to it.
- It does not start long jobs on its own: image bakes and installs wait for you.
- It does not fix failed CI jobs in your repositories, only the fleet that runs them.
- It does not act on setup checks outside runtimes and images (config, Command Line Tools, architecture): those stop a
  fleet before there is anything to heal.
- It does not touch instances kinhin has no record of; the orphan sweep handles those.
- It does not coordinate between Macs. Each Mac heals its own fleet.

## Where things live

| What | Where |
| ---- | ----- |
| The journal (last 100 entries, owner-only) | `~/Library/Application Support/Kinhin/state/healing.json` |
| Log lines | `kinhin logs`, component `healing` |
| The rules | `Sources/KinhinKit/Fleet/Healing/HealingPlaybook.swift` |
| The design | [plans/healing-agent.md](plans/healing-agent.md) |
