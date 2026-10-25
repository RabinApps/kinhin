# How scaling works

The capacity cap, the scaling loop, job density, and how kinhin recovers from restarts.

[← Back to README](../README.md) · Why this exists: [Why kinhin](why.md)

## Capacity

The effective concurrency cap is
`min(max_runners, (cores − reserve.cpu) / vm.cpu, (RAM − reserve.memory_gb) / vm.memory_gb, free_disk / disk_per_vm)` —
`disk_per_vm` is your `disk_gb` when set, else a runtime default (50 GB for Tart VMs, 8 GB for
Linux container slots). The scaler re-checks free disk before every spawn and holds new VMs when
the disk would dip below `reserve.disk_gb` plus one instance's footprint — a queue burst can
never fill your disk. `kinhin doctor` prints the cap and the binding constraint, and warns under
the same rule before the fleet reaches it: `WARNING: disk pressure` (the guard itself is the
`diskPressure` field of `doctor --json`), stating how much the images hold and what
`kinhin image prune` would reclaim.
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

When starts keep failing.

If a runtime's instances fail to register twice in a row (a bad image, a runner
that exits at once), kinhin stops respawning them in a loop: that runtime waits 30 s, then 1 min, 2 min … up to
10 min before the next attempt, other runtimes keep going, and the status line shows `runner starts failing on
<reason> … retrying in Ns: </reason>` with the runner's own output. One successful registration clears it. A job
cancelled on GitHub before a runner picks it up is not a failure: the idle instance is simply removed
(`cancelled remotely` in the log).

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

## Warm pool

`warm_pool: N` keeps `N` Tart VMs cloned, booted and SSH-ready but **not registered** with any forge. When a job
arrives, the scaler claims a warm VM, binds it to the account that has the demand, and runs only the registration step,
so the job skips `tart clone` and boot. With the default `0` the feature is off.

Each Tart image has its own pool. The top-level `warm_pool` covers `image:`, and `warm_pool` on an
[`images:` entry](runtimes.md#multiple-macos-images) covers that image, so an Xcode image can stay warm while the base
stays cold, or the other way round.

- Warm VMs take slots under `max_runners` and count against the capacity cap, including Apple's limit of two macOS VMs
  per Mac. They are evicted when a job needs the slot, so a warm VM never delays work that a cold start could serve.
- The pool tops up only when nothing is queued and `min_runners` is met. In ephemeral mode the replacement for a
  finished VM is started on the next pass, so the poll interval applies.
- A job claims a warm VM of the image it runs on. Jobs routed to a per-project image (`projects:`), and the other
  runtimes, start cold.
- A named image that was never prepared gets no warm VMs. Its `warm_pool` is skipped, with a log line, until it exists. Kinhin reads `tart list` at most once a minute, so an
  image prepared while the fleet runs starts its warm pool within a minute.
- The base `warm_pool` and every entry's `warm_pool` together must fit in `max_runners`.
- A warm VM older than `warm_max_age_minutes` (default 60) is recycled, and so is one whose pool is turned off or whose
  `images:` entry was removed. After a restart, warm VMs are re-checked rather
  than trusted.

This differs from `min_runners`, which keeps *registered* idle runners on the forge.

## Healing

The scaling loop recovers from most failures by itself: the spawn backoff above, teardown retries, forge re-attach
backoff, and an orphan sweep for instances kinhin started but has no record of (see [Restarts](#restarts)). The [healing agent](healing.md) runs in its
own loop beside it and covers what those do not, without ever delaying a scaling pass:

- **Warm VMs.** A warm VM waits with nothing driving it, so no liveness watch sees it die. The engine's orphan sweep
  (every 2 minutes, healing on or off) lists each runtime once and removes the record of a warm VM deleted or stopped
  outside kinhin, so it stops holding a slot and the pool tops up again; the healing journal notes each removal.
- **Disk pressure.** When the disk guard holds spawns, the agent prunes the toolchain cache (with `auto_prune` on) and
  then asks before pruning unused images.
- **Spawn backoff.** The backoff keeps a failing runtime from respawning in a loop; the agent looks at why. A stopped
  Apple container system is started on its own; a missing runtime or a broken tart waits for your approval.
- **Detached accounts.** An account that dropped off for a minute is re-attached at once instead of waiting out its
  backoff; a rejected token is shown to you.

With `healing.enabled: false` all of the engine's own retries still run. `kinhin heal` shows what the agent did.

## Restarts

When the daemon or app restarts, kinhin reads its saved state (`fleet.json` in the state directory) and checks what is still
running on each runtime before it starts anything new.

- **Intact `fleet.json`.** Records are reloaded. A runner that was registered (idle or busy) is watched, not registered again,
  so its job is not disturbed. The exception is an idle classic (non-ephemeral) runner in an Apple container or Docker
  container: the agent dies with a stopped container, so when the forge lists runners and has none for it, it is registered
  again. A warm VM returns to the warm pool.
- **Unreadable `fleet.json`.** kinhin moves the file aside to `fleet.json.corrupt-<timestamp>` (it is never overwritten), and
  the status alert and `kinhin status` name the kept copy. The engine starts with no VM records, so job and repo attribution
  is lost. It then re-adopts each VM it finds and checks that VM's runner with the forge, asking each account once:
  - a runner the forge still has (busy or idle) is **watched, not registered again**, so a running job is not disturbed;
  - a VM with no runner on the forge is registered as normal;
  - a VM whose forge cannot be asked is **held** and not registered until it can be (shown by the `adoption` status alert).

  Beta 2 registered every re-adopted VM again, which could fail a running job (see the known issue in
  [GitHub forge notes](forges/github.md)). The fix shipped in beta 3; on beta 2, restart only when no jobs are running.
- **Unlisted runtime.** If a runtime can't be listed (Tart wedged, a daemon down), its records are kept, and nothing is removed
  on a failed listing.
- **Orphan sweep.** Only an instance with no record, under a name kinhin generates, is removed, and only after it stays
  unclaimed for ten minutes (`orphanGrace`). An instance the restart re-adopted has a record, so the sweep does not remove it.
- **Warm VMs after an unreadable `fleet.json`.** The pool flag is lost, so a re-adopted warm VM comes back as an ordinary runner.
  It counts against `max_runners` until scale-down removes it.
- **Forges with no runner list.** Some servers (Gitea before 1.24, Forgejo, Bitbucket) cannot say which runner belongs to which
  VM. With nothing running in the account's scope, a re-adopted VM is registered. With a job running, it is watched as busy, and
  it is removed once the scope goes quiet.
- **Partly registered VMs.** With `runners_per_vm` above 1, a VM can have only some of its runners on the forge. If none of them
  is busy, the set is registered again. If one is busy, the VM is watched. The missing runner never appears, so the VM is removed
  only at the watch deadline (up to 6 hours). This is a known limit.
- **Accounts without a forge.** A VM whose account is still configured but has no forge attached is held, with the `adoption`
  status alert, and removed after one hour. A VM whose account was removed from the config is released at once.

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

With a GitHub scale set (`scale_set:`), keep `runners_per_vm: 1`: GitHub does not hand a second job to another idle
runner in the same VM, and the scaler counts those slots as capacity, so the job waits for the first one to finish
([details](forges/github.md#a-second-job-stays-queued-while-the-vm-has-idle-runners-runners-per-vm-1)).

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

### Requeue and skip

From the Fleet tab, the **Requeue** and **Skip** buttons in the _Requeue / skip queued_
section cancel or drop the queue's matching jobs. Org-scope forges re-queue/skip the
fleet-wide queue; repo-scope forges act on that one forge. Both are single-command
actions behind the same pending-state and AlertKit failure handling as Start/Stop.

See [Requeue and skip queued jobs](requeue-skip.md) for the full behavior.
