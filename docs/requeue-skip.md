# Requeue and skip queued jobs

The Fleet tab now lets you re-queue or drop the fleet's queued jobs, per forge, from
the **Requeue / skip queued** row (one button per attached forge).

## Where it appears

Every attached forge gets a row in the "Requeue / skip queued" section with a
**Requeue** and **Skip** button:

```
Requeue / skip queued
  github
    [Requeue] [Skip]
  gitea
    [Requeue] [Skip]
```

The per-forge choice of scope is shown with a small menu on each row:

- **Org scope** (no slash in the forge's scope): the faucet is fleet-wide, so
  the button re-queues/skips the whole fleet's queue across *every* attached forge.
- **Repo scope** (a slash like `acme/widgets`): the button targets only that one
  forge.

A **Start/Stop is in flight** disables all four buttons — the same state backstop
as the Stop/Pause row.

## What they do

`FleetController.requeueQueuedJobs(for:)` and `FleetController.skipQueuedJobs(for:)`
are the throwing app-facing actions. Both:

1. Guard against a command already running (`pendingFleetAction`).
2. Dispatch through whichever backend is live — the in-process engine or the
   daemon — via `FleetBackend`.
3. Run the engine operation, then **refresh the status** so the UI shows the
   re-queued/dropped work coming back or draining.

The engine operation itself lives on each queue-capable forge. GitHub (the only
queue-capable forge today) is implemented through the GitHub client's
`cancelWorkflowRun(ids:)` / `skipWorkflowRun(ids:)`. `EngineError.forgeNotFound`
is raised when the requested forge has no queue implementation.

The in-VM work is unchanged — these operations only touch the forge's queue of
queued jobs, never a running job or instance.

## Adding a queue-capable forge

A forge supports requeue/skip by conforming to the `ForgeWithQueuedJobs` protocol
in `KinhinKit/Forges/Forge.swift`:

```swift
public protocol ForgeWithQueuedJobs: Forge {
    func userRequeueQueuedJobs() async throws
    func userSkipQueuedJobs() async throws
}
```

The engine dispatches `(requeue|skip)QueuedJobs(for:)` on the engine itself to
the concrete forge type; no fleet-controller change is needed. The requirements
are:

- `userRequeueQueuedJobs()` cancels the queued jobs matching the fleet's labels
  and re-queues them downstream.
- `userSkipQueuedJobs()` drops those jobs as skipped.

Only the client of that forge needs to answer `cancelWorkflowRun(ids:)` /
`skipWorkflowRun(ids:)` (which accepts a run id — work with fine-grained
granularity, not the job's numeric id) and return whether each was dropped.

## UI and failure handling

- A denied or failed requeue/skip surfaces an alert titled
  *"Couldn't requeue the queued jobs"* / *"Couldn't skip the queued jobs"* via
  `AlertKit`, with the pending flag cleared.
- A failed command is followed by a fresh status poll so the tab shows the state
  the backend actually settled into.
- The buttons disable while a start/stop is in flight, and a second click while
  busy is a no-op.

## Managing the fleet from the CLI

The `kinhin` headless CLI drives the fleet's lifecycle and its queued-job queue.
Queue operations dispatch through the live backend (daemon or, in the app, the
in-process engine) the same way the Fleet tab does.

| Command | What it does |
| ------- | ------------ |
| `kinhin start` | Starts the fleet in the current terminal (Ctrl-C to stop). Runs the engine in-process. |
| `kinhin stop` | Stops the fleet — dispatches to the daemon if one is alive, otherwise finds an in-process engine to stop. |
| `kinhin pause` / `kinhin resume` | Hold the fleet / let it scale again. Requires a running daemon. |
| `kinhin status [--json]` | Show fleet status (queue depth, VMs, jobs). Attach to the daemon if running. |
| `kinhin watch` | Live status view, refreshes every 2s. |
| `kinhin daemon` | Run the headless daemon in the current terminal. |
| `kinhin requeue <forge> [--yes]` | Cancel the fleet's queued jobs on a forge and re-queue them. Requires the daemon; prints the dry-run intent unless `--yes` confirms. |
| `kinhin skip <forge> [--yes]` | Mark the fleet's queued jobs on a forge as skipped. Requires the daemon; prints the dry-run intent unless `--yes` confirms. |
| `kinhin logs [-n N]` / `kinhin cleanup` | Logs and disk-reclamation commands. |

### Requeue and skip

`kinhin requeue <forge>` and `kinhin skip <forge>` talk to the daemon over the
same `requeue_queued_jobs` / `skip_queued_jobs` RPC methods the app uses; the CLI
has no in-process backend of its own. Before dispatching, each command:

1. Parses `<forge>` as a `ForgeID` (unknown values list the forges already in
   config or the known forges and suggest adding the forge first).
2. Prints the dry-run intent (`would requeue …` / `would skip …`) unless
   `--yes` is given, so headless scripts can preview without side effects.
3. Fails with `no daemon running; requeue/skip works while a daemon is active`
   when the daemon is absent.

Pending-state backstop, the in-app `AlertKit` failure alert, and the
refresh-after-command path live in the app's `FleetController` and its App Intent
bridge, so the Fleet tab buttons and status-bar menu keep their UX. The CLI path
is the unattended / remote complement: run the daemon on the Mac, then
`kinhin requeue github --yes` or `kinhin skip github --yes` from another terminal
or script.

## Tests

`Tests/KinhinAppTests/FleetRequeueSkipTests.swift` covers pending state, backend
dispatch, refresh after success, failure surfacing, and the no-backend throw.

## Verification and CI

The fleet requeue/skip path is covered by two suites: `Tests/KinhinAppTests/FleetRequeueSkipTests`
(controller actions, pending state, refresh, AlertKit failure surfacing, no-backend throw) and
`Tests/KinhinAppTests/FleetDetailModelTests` (filter behavior, breakdown rendering, drill-down).
Both use the `FakeFleetServing` test double, which records `requeueQueuedJobs(for:)` and
`skipQueuedJobs(for:)` calls so CI can assert pending-state and backend dispatch precisely.

The CI build and test sequence is:

```bash
swift build
swift test
swift format lint --strict -r Sources Tests
bash scripts/docs-refs.sh check
```

`swift test` runs the full `KinhinAppTests`, `KinhinKitTests`, and `KinhinCLITests` trees
including the new `FleetRequeueSkipTests` and `FleetDetailModelTests`. The CI gate is green
when the build compiles, the suites pass, and the strict formatter reports no new deviations.

## See also

- [How scaling works](scaling.md) — the queue/running breakdown this row feeds.
