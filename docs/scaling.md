# How scaling works

The capacity cap, the scaling loop, job density, and how kinhin recovers from restarts.

[← Back to README](../README.md)

## Capacity

The effective concurrency cap is
`min(max_runners, (cores − reserve.cpu) / vm.cpu, (RAM − reserve.memory_gb) / vm.memory_gb, free_disk / disk_per_vm)` —
`disk_per_vm` is your `disk_gb` when set, else a runtime default (50 GB for Tart VMs, 8 GB for
Linux container slots). The scaler re-checks free disk before every spawn and holds new VMs when
the disk would dip below `reserve.disk_gb` plus one instance's footprint — a queue burst can
never fill your disk. `kinhin doctor` prints the cap and the binding constraint.

When several runtimes are configured, this budget is partitioned across their pools by the
`runtimes.budget` weights (see [Runtimes](runtimes.md#per-repo--per-workflow-runtime-routing)).

## The scaling loop

Every `poll_interval` seconds the engine:

1. Cleans up any failed instances from the previous pass.
2. Asks each forge for queued jobs on its scope and filters them by `labels`.
3. **Routes** each job to a runtime — workflow route → repo route → `runs-on:` label → default —
   and buckets the demand per pool.
4. Computes the desired instance count **per pool**:
   `desired = clamp(ceil(pool_queue / runners_per_vm), min_runners, pool_cap)`, where `pool_cap`
   is that runtime's slice of the host budget (`budget` weights) when multiple runtimes are
   configured, or the full [capacity cap](#capacity) for a single-pool fleet.
5. Spawns instances up to `desired` (linked clone → boot → SSH → register `runners_per_vm`
   runners → `run.sh`) — Tart VMs for macOS pools, apple containers or Docker slots for Linux pools,
   and a runner process on the Mac itself for host routes.
6. Deletes idle instances when `desired` drops (scale to zero by default).

### Poll cadence

`poll_interval` is the cadence whenever there is something to react to. Two things stretch it:

- **Idle.** A running fleet with no queued jobs and no instances for 5 minutes polls every 60s
  (or every `poll_interval`, if that is longer). The first new job restores the normal cadence.
  The 5-minute grace keeps multi-stage workflows fast: the fleet is briefly empty between `needs:`
  stages, and those gaps never slow the next stage. Resuming a paused fleet or reloading routing
  triggers a poll immediately.
- **API budget.** kinhin reads GitHub's rate-limit headers on every response. Below 25% of the
  hourly budget it polls half as often, and below 10% a quarter as often, and it stops reading
  running jobs (the per-repo "running" breakdown) so demand reads keep working. When the budget
  is exhausted, it waits for the reset (at most 15 minutes).

A paused fleet never backs off for idleness, because the status surfaces promise to re-check the
queue every `poll_interval`. The status line notes a slowdown, e.g.
`queue age: 12s old · checking every 60s (idle)`, and a queue is only reported as stale when it is
older than the cadence currently in effect.

GitHub reads are conditional (`If-None-Match`), so a poll that finds nothing changed gets a 304,
which does not count against the rate limit. Every live instance's exit watch reads one shared
runner list, refreshed at most every few seconds, instead of one list per instance per second.

## Pausing and auto-resume

A paused fleet skips spawning (and, by default, skips queue polling entirely). With
`auto_resume: true` the engine keeps watching the queue while paused — on the normal
`poll_interval` cadence, read-only — and unpauses itself in the pass that finds it empty: a
deliberate pause (for example the Shortcuts "Delete VM" action pauses first so autoscaling
can't recreate what was deleted) then releases the fleet on its own. If every forge fetch fails
while paused, the engine holds: silence must not read as "nothing to do".

Every surface that can show a paused fleet shares one cadence clause while the policy holds —
the menu bar and Fleet tab status line, `kinhin status`, and Siri all render (with your
configured `poll_interval`) that the engine "re-checks the queue every 20s and resumes once
it's empty". Because only a forge *answering* a demand fetch refreshes the queue numbers,
every status surface stamps them with an age: `kinhin status` prints `queue age: Ns old` and the
menu bar and Fleet tab status line adds a `⏱ queue age: Ns old` line — stale during an outage, so a
paused snapshot never masquerades as fresh. `kinhin status --json` exposes the same facts as fields:
`paused`, `autoResume`, `pollInterval`, `queueAgeSeconds`.

## Job density

`runners_per_vm` is the density knob: with the default `1`, each job gets its own VM (most
isolation); with `4`, one VM serves four concurrent jobs before the scaler spawns another. Small
jobs on identical macOS stacks are the sweet spot — set it high enough that `vm.cpu`/`vm.memory_gb`
cover the _sum_ of the jobs you expect on one VM.

## Running on multiple Macs

Each Mac runs its own engine and polls the forge independently; kinhin does not coordinate between
machines (the daemon lock only guards against two daemons on the _same_ Mac). If two Macs serve the
same repo with the same labels, both see a queued job and both spawn a runner for it. The forge
hands the job to exactly one of them, so it never runs twice, but the other Mac boots a VM it didn't
need.

To keep demand from overlapping, give each Mac its own label:

```yaml
# Mac A
labels: ["mac-a"]
```

```yaml
# Mac B
labels: ["mac-b"]
```

A workflow then picks the Mac it wants:

```yaml
runs-on: [self-hosted, macos, arm64, mac-a] # only Mac A spawns for this job
```

A job counts as demand only when it requests _every_ configured label, so the other Mac ignores it.
To fan one job across both Macs, use a matrix:

```yaml
strategy:
  matrix:
    mac: [mac-a, mac-b]
runs-on: [self-hosted, macos, arm64, "${{ matrix.mac }}"]
```

Things to know:

- A job with neither label matches no Mac and stays queued.
- A shared pool (the same labels on both Macs) still works, but a burst can make both Macs spawn.
  Lower `max_runners` on the weaker Mac to limit the waste.

## Lifecycle and recovery

Ephemeral runners register with `--ephemeral`, so GitHub removes the runner registration as soon
as the job finishes; kinhin then deletes the VM. If the engine crashes or restarts it reconciles
`tart list` against its persisted state, adopts orphaned VMs, and drops records whose VMs vanished.

Registration tokens are short-lived (1 h); kinhin caches and refreshes them automatically. Your
PAT lives in the login Keychain.

Config edits made from the app's **Advanced → Routing** tab (routes, budget split, labels) reach a
running fleet live via `reload_config` — no restart; a running fleet simply re-buckets demand on
its next poll.
