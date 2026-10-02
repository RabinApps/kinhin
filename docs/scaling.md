# How scaling works

The capacity cap, the scaling loop, job density, and how kinhin recovers from restarts.

[← Back to README](../README.md) · Why this exists: [Why kinhin](why.md)

## Capacity

The effective concurrency cap is
`min(max_runners, (cores − reserve.cpu) / vm.cpu, (RAM − reserve.memory_gb) / vm.memory_gb, free_disk / disk_per_vm)` —
`disk_per_vm` is your `disk_gb` when set, else a runtime default (50 GB for Tart VMs, 8 GB for
Linux container slots). The scaler re-checks free disk before every spawn and holds new VMs when
the disk would dip below `reserve.disk_gb` plus one instance's footprint — a queue burst can
never fill your disk. `kinhin doctor` prints the cap and the binding constraint.
Not sure how big a Mac you need? See [Hardware requirements & sizing](hardware.md).

When several runtimes are configured, this budget is partitioned across their pools by the
`runtimes.budget` weights (see [Runtimes](runtimes.md#per-repo-and-per-workflow-routing)).

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
   runners → `run.sh`) — Tart VMs for macOS pools and for Tart Linux VMs, apple containers or
   Docker slots for the container Linux pools (see [Choosing a Linux runtime](runtimes.md#choosing-a-linux-runtime)),
   and a runner process on the Mac itself for host routes.
6. Deletes idle instances when `desired` drops (scale to zero by default).

### Poll cadence

`poll_interval` is the normal cadence. Two things stretch it:

- **Idle.** After 5 minutes with no queued jobs and no instances, kinhin polls every 60s (or `poll_interval`, if
  longer). The first new job restores the normal cadence. The 5-minute grace keeps multi-stage workflows fast, because
  the fleet is briefly empty between `needs:` stages.
- **API budget.** kinhin reads GitHub's rate-limit headers. Below 25% of the hourly budget it polls half as often, and
  below 10% a quarter as often. When the budget is exhausted it waits for the reset (at most 15 minutes). The status
  line notes any slowdown, for example `queue age: 12s old · checking every 60s (idle)`.

GitHub reads are conditional, so a poll that finds nothing changed gets a 304, which doesn't count against the rate
limit.

## Pausing and auto-resume

A paused fleet doesn't spawn new instances. With `auto_resume: true` it keeps watching the queue while paused and
resumes itself once the queue is empty. This is what makes a deliberate pause safe, for example the Shortcuts "Delete
VM" action pauses first so autoscaling can't recreate what you just deleted. If every forge fetch fails while paused,
the engine stays paused rather than treat silence as "nothing to do".

Every status surface (menu bar, Fleet tab, `kinhin status`, Siri) shows how old the queue numbers are, so a paused
snapshot never looks fresh during an outage. `kinhin status --json` exposes `paused`, `autoResume`, `pollInterval` and
`queueAgeSeconds`.

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

Ephemeral runners register with `--ephemeral`, so GitHub removes the registration as soon as the job finishes, and
kinhin then deletes the VM. If the engine crashes or restarts, it compares `tart list` with its saved state, adopts
orphaned VMs, and drops records whose VMs vanished.

Registration tokens last an hour and are refreshed automatically. Your PAT lives in the login Keychain. Config edits
from **Advanced → Routing** reach a running fleet without a restart.
