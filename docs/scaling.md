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

### Requeue and skip

From the Fleet tab, the **Requeue** and **Skip** buttons in the *Requeue / skip queued*
section cancel or drop the queue's matching jobs. Org-scope forges re-queue/skip the
fleet-wide queue; repo-scope forges act on that one forge. Both are single-command
actions behind the same pending-state and AlertKit failure handling as Start/Stop.

See [Requeue and skip queued jobs](requeue-skip.md) for the full behavior.

## Scale set mode (opt-in)

A GitHub account can opt in to GitHub's Runner Scale Set message API instead of the classic REST workflow-runs poll.
This is one account at a time, in `config.yaml`:

```yaml
accounts:
  - name: github
    forge: github
    scope: your-org # org or owner/name
    scale_set: # absent → classic poller (default)
      name: kinhin
      # runner_group: default
```

`scale_set.name` is the scale-set name base. The engine derives per-pool names from it (for example `kinhin`,
`kinhin-container`, `kinhin-docker`), so one fleet can run a scale set per runtime pool. The scale-set name is also a
valid `runs-on:` label, so a workflow can target it directly.

When an account has `scale_set:` set, kinhin does the following for that account:

- Mints runner-registration material through the Actions service, then ensures the scale set and runner group exist.
- Opens a long-poll message session and drives demand from the scale-set statistics and job messages instead of polling
  workflow runs.
- Registers each spawned runner with a JIT config rather than a shared runner token.

This mode is useful when you want event-driven pickup instead of poll latency, or when you'd rather avoid repeated REST
reads against the rate-limit budget. The autoscaler still works the same way: scale-set mode still uses
`TotalAssignedJobs` for demand, and pause/auto-resume, `max_runners`, `min_runners`, `runners_per_vm`, budget caps and
disk-pressure holds are unchanged. `poll_interval` still paces reconcile passes and scale-downs.

A few things to know:

- The scale-set message API is **opt-in and not documented in GitHub's published REST API descriptions**. kinhin
  implemented it from the actions/scaleset client and its API surface; treat it as preview-grade as long as GitHub
  keeps that API in preview.
- The scale-set listener replaces where demand comes from; it does not change provisioning. Spawning, cloning, boot,
  SSH, runner registration and teardown still follow the same runtime path.
- Scale-set runners are one-job ephemeral by design. The engine still deletes idle instances when demand drops.
- When the listener cannot refresh statistics, it keeps serving the last known snapshot so the fleet does not read zero
  demand from a transient failure.

### Scale set config

`scale_set:` requires `vm.ephemeral: true`. Scale-set runners deregister after one job, so persistent VMs are
contradictory. The scale-set name must be a valid `runs-on:` label segment. If `runner_group` is omitted, kinhin uses the
default runner group.

### JIT registration

In scale-set mode, spawned runners register with `./config.sh --jitconfig '<config>' --unattended --replace --work _work`
and do not receive a shared runner token. Registration material is treated like other secrets: it is not logged and is
redacted in logs.

### Limitations

- GitHub Enterprise Server is not supported; the Actions service path kinhin uses is github.com-only.
- Deleting scale sets on teardown is not in scope; they are left in place and re-attached.
- There is currently no Fleet-tab card or account-form toggle for scale sets; the only control is the `scale_set:` key in
  config. If you add one, the app and CLI must not drop the key when rewriting the `accounts:` block.

See [GitHub API notes](forges/github.md#scale-set-mode-in-kinhin) for the endpoint path kinhin uses and the current
preview/API-version caveats.
