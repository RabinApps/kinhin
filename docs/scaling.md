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

From the Fleet tab, the **Requeue** and **Skip** buttons in the _Requeue / skip queued_
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

### Runner images and per-VM directories

Scale-set mode on Github Runners uses the same baked images as classic mode — there is no separate scale-set image to prepare. The only
difference is the registration script the engine pushes into a booted VM over SSH: classic runners use
`config.sh --url ... --token ...`, scale-set runners use `config.sh --jitconfig <config>`.

For GitHub Actions Tart VMs, `kinhin image prepare` bakes the runner agent into `~/actions-runner` (macOS) or
`/opt/actions-runner` (Linux) and, when the bake was run with `runners_per_vm > 1`, also pre-creates the sibling
directories `~/actions-runner-2..N` / `/opt/actions-runner-2..N`. The registration scripts (classic and JIT) place:

- the first runner in `~/actions-runner` / `/opt/actions-runner` (the baked template directory), and
- runners 2..N in `~/actions-runner-2..N` / `/opt/actions-runner-2..N`.

If a scale-set fleet runs `runners_per_vm: 2` but the image was baked with `runners_per_vm: 1` (so only the template
directory exists), the JIT registration script copies the template into the second runner's directory at registration time
— the same best-effort fallback the classic multi-runner script already used. To avoid that per-VM copy, bake the image
with the same `runners_per_vm` you run the fleet at.

If a scale-set VM's base image did not have the runner baked in at all (for example a third-party image), the JIT
registration script can download the GitHub Actions runner agent from the releases feed into the per-runner directory
instead of failing. The version it downloads is the pinned fallback from `RunnerVersionResolver` (the same version
`kinhin image prepare` uses when the feed is unreachable). This fallback is a rescue path only: a properly prepared
image is still the normal case.

### Troubleshooting scale sets

Most scale-set failures are either the local spawn path (VM won't boot / SSH / runner can't find its directory) or the
GitHub Actions-service path (no admin token, scale set or runner group missing, session drops). Separate them by where the
log line is printed.

#### Read the right log surface first

- `kinhin log` and the Fleet tab show the engine log, including the per-instance tag `[kinhin-<uuid>]`.
- When a VM fails to register, the error is usually on the line that starts with `lifecycle failed:` or `could not pin the
guest's SSH host key`.
- The `_work` folder path in the error (`/Users/admin/actions-runner-1`, `/opt/actions-runner-2`, …) tells you the
  registration script reached the VM but the directory it expected doesn't exist — count the runner index in that path against
  your bake density (see below).

#### `cd: /Users/admin/actions-runner-N: No such file or directory` (or the Linux equivalent)

This means the JIT registration script was told to register a runner into a per-runner directory that isn't on the image.
The usual cause is a density mismatch between the baked image and the fleet.

- Scale sets do **not** use a separate image. The same `kinhin image prepare` output that works for classic mode is also
  what scale-set VMs boot.
- An image baked with `runners_per_vm: 1` has only the template directory (`~/actions-runner` on macOS, `/opt/actions-runner`
  on Linux). A scale-set fleet running `runners_per_vm: 2` also needs `~/actions-runner-2` / `/opt/actions-runner-2`. When the
  second directory is missing, the JIT script copies the template into it at registration time — best-effort, and still
  needs the template dir to exist.
- If you see `actions-runner-1` in the error, the script indexed one too high: that is the symptom the density mismatch
  produces, because runner 1 should land in the template directory, not in `actions-runner-1`.

To fix it, bake the image with the same `runners_per_vm` you run the fleet at, then restart the fleet so it picks up the
new image. If you cannot re-bake right now, lower `runners_per_vm` on the scale-set account to match the image until you can.

#### SSH host key warning + `connecting without host key verification`

```
could not pin the guest's SSH host key (tart exec … failed: … is the Tart Guest Agent running?);
connecting without host key verification. A hostile VM on a shared network could impersonate this one:
set tart_softnet: true (docs/security.md)
```

This is a boot connectivity issue, not a registration-material issue. The engine reached the VM over SSH but couldn't pin
the host key, so it proceeds without verification and logs the warning. Common causes:

- The VM's control socket isn't reachable yet (still booting). The engine retries; if the second attempt succeeds the rest
  of the line proceeds normally.
- The Tart Guest Agent isn't running inside the guest, or the guest image doesn't have it. Verify the image boots and
  responds to SSH on a single-VM test before scaling it in a fleet.
- Network isolation interferes with the control path. The doc cited in the warning describes the `tart_softnet` escape hatch
  and the trade-off.

If every instance prints this and then fails with a lifecycle error, treat it as an image/agent problem, not a scale-set
problem: establish that one VM can boot and register in classic mode first.

#### `runner registration failed … bash: line …: cd: …: No such file or directory`

This is the same family as the directory-not-found error above, surfaced inside the in-VM registration script instead of the
engine log. The fix is the same: ensure the per-runner directory exists on the image (bake density matches fleet density) or
that the template directory exists and the script can copy it.

#### Missing runner agent on the image

If the base image had no GitHub Actions runner baked in at all (for example a third-party or hand-rolled image), the JIT
registration script attempts to download the runner agent from the GitHub releases feed into the per-runner directory instead
of failing immediately. That download:

- uses the pinned fallback version from `RunnerVersionResolver`, the same version `kinhin image prepare` falls back to when
  the releases feed is unreachable;
- is a rescue path, not the normal case — a properly prepared image is still what you want for a scale-set fleet;
- can still fail if the VM has no outbound HTTPS to `github.com` from the Actions-service network path.

If you see a registration failure that looks like a download failure rather than a missing-directory failure, confirm the
image actually has the runner (see next section) before re-baking.

#### How to tell whether an image has the runner baked in, and at what density

On a booted VM (or on the host image before booting), check the runner directories:

- macOS Tart guest: look for `~/actions-runner` (the template dir) and, if baked for density, `~/actions-runner-2` …
  `~/actions-runner-N`.
- Linux guest: look for `/opt/actions-runner` and, if baked for density, `/opt/actions-runner-2` … `/opt/actions-runner-N`.

If the template directory is present and contains the runner (`config.sh`, `run.sh`, `.runner`, `_work`), the image has the
agent and can register runner 1 directly. If sibling directories are present too, the image is ready for that density without
the per-VM copy fallback. If the template directory is absent entirely, the image has no baked runner and the JIT script will
try the download fallback (or fail if it can't reach the feed).

#### Scale set or runner group not found

```
runner group '<name>' was not found; create it in GitHub before attaching
```

or a scale-set ensure call that returns 404-style "not found" on the runner group or scale set.

- `scale_set.runner_group` is optional; when absent, kinhin uses the default runner group. If your org/enterprise requires a
  named group, set `runner_group:` explicitly.
- Scale sets are created through the Actions-service preview path under `api-version=6.0-preview`. If the admin JWT exchange
  or the scale-set ensure calls fail consistently, confirm the account's PAT has the organization self-hosted-runner
  permissions the GitHub forge doc lists, and that the account is github.com (the Actions-service path is not wired for
  GHES in this mode yet).
- Scale sets are left in place on teardown and re-attached; a leftover scale set from a previous fleet is normally fine.

#### Sessions drop / listener can't refresh statistics

If the Fleet tab or `kinhin status` shows stale queue numbers, or you see repeated listener reconnect attempts:

- The listener keeps the last known statistics snapshot when it can't refresh, so a transient failure shouldn't read as zero
  demand. Stale-but-nonzero is expected briefly; stale-and-growing is not.
- A 401 on the message session triggers a session refresh. If refreshes keep failing, the admin JWT may be expired or the
  account's token may have lost the needed scopes; re-auth the account (`kinhin auth set --github` or the Connect form).
- Long-running listeners still respect `poll_interval` for reconcile passes and scale-downs; a quiet period is normal.

#### Switching an existing account to scale set

If a GitHub account already ran in classic mode and you add `scale_set:`:

- No image rebuild is required for the common case: the same baked image works for both modes. The only in-VM difference is
  the registration script (classic uses `--url/--token`, scale set uses `--jitconfig`).
- If the account's image was baked for a density the scale-set fleet won't match, see the density-mismatch error above.
- If the account's image has no baked runner at all, the scale-set JIT path will try the download fallback; classic mode may
  already have been failing on that image too.

#### Things that are not scale-set-specific

- Ephemeral + `vm.ephemeral: true` is required for scale-set accounts; a persistent-VM config is contradictory with one-job
  ephemeral scale-set runners. If scale-set attach fails immediately with a config error, check that first.
- Pause/auto-resume, `max_runners`, `min_runners`, budget caps, disk-pressure holds, and recovery-on-restart behave the same
  in scale-set mode as in classic mode. If those are misbehaving, the cause is usually the config or the host budget, not the
  scale-set mode.

### Limitations

- GitHub Enterprise Server is not supported in scale-set mode yet; the Actions-service path kinhin uses is github.com-only.
- Deleting scale sets on teardown is not in scope; they are left in place and re-attached.
- There is currently no Fleet-tab card or account-form toggle for scale sets; the only control is the `scale_set:` key in
  config. If you add one, the app and CLI must not drop the key when rewriting the `accounts:` block.

See [GitHub API notes](forges/github.md#scale-set-mode-in-kinhin) for the endpoint path kinhin uses and the current
preview/API-version caveats.
