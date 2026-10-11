# End-to-end testing

`swift test` runs about 2,900 tests against fakes (`FakeTart`, `FakeSSH`, `FakeGitea`, ...) in two minutes with no VMs
and no network. That keeps the suite fast, but it can only prove kinhin agrees with its own model of a forge or a
runner. The end-to-end (e2e) suite in `Tests/E2E` checks the model against the real thing: a real forge in a
container, a real kinhin daemon, a real runner image, and a job that really runs inside a guest.

[← Back to README](../README.md) · [Contributing](../CONTRIBUTING.md) · [Adding a forge](adding-a-forge.md)

## How it is built

- **A separate Swift package** (`Tests/E2E/Package.swift`). The root `swift test` and `scripts/check.sh` can never
  load it, so nothing here boots a container unless you run `scripts/e2e.sh`.
- **Swift Testing**, not XCTest: parameterized `@Test(arguments:)` gives the forge × runtime matrix for free, tags
  group the tiers, and one `.serialized` parent suite (`Infra`) keeps the heavy suites from fighting over the Mac.
- **A black box.** The suite drives the real `kinhin` binary as a subprocess and judges outcomes by what the forge
  itself reports, never by kinhin's own view of events. It has no dependency on `KinhinKit`.
- **Sandboxed.** Every scenario gets its own support directory (`KINHIN_SUPPORT_DIR=/tmp/ke2e-<id>`: config, state,
  logs, daemon socket) and reads its forge tokens from the environment (`KINHIN_TOKEN_STORE=env`, a debug-build
  feature). It never touches your real config, daemon or Keychain. This is why `scripts/e2e.sh` builds a **debug**
  `kinhin`.

## Running it

```bash
scripts/e2e.sh                # quick: CLI, security and coverage guards. Seconds, no Docker.
scripts/e2e.sh --local        # + real Gitea/Forgejo lifecycle, fleet behavior, smoke toolchains (Docker, container)
scripts/e2e.sh --full         # + GitLab CE and the whole toolchain catalog (hours, several GB)
scripts/e2e.sh --local -- --filter LifecycleTests     # anything after -- goes to `swift test`
```

`--full` turns the Tart macOS (`macos-tahoe-base`), Tart Linux (`ubuntu`) and host lanes on unless their variables
are already set. Narrow the matrix with environment variables:

| Variable                                            | Effect                                                                         |
| --------------------------------------------------- | ------------------------------------------------------------------------------ |
| `KINHIN_E2E_FORGES=gitea,forgejo`                   | Only these forges (`gitea`, `forgejo`, `gitlab`, `github`)                     |
| `KINHIN_E2E_RUNTIMES=docker,appleContainer`         | Only these runtimes                                                            |
| `KINHIN_E2E_HEAVY=1`                                | Include GitLab CE (several GB, minutes to boot)                                |
| `KINHIN_E2E_TOOLCHAINS=full`                        | The whole toolchain catalog instead of the smoke set                           |
| `KINHIN_E2E_TART_BASE=<macOS tart image>`           | Turn on the Tart macOS lane (bakes from it with `image prepare --source`)      |
| `KINHIN_E2E_TART_LINUX_BASE=<Linux tart image>`     | Turn on the Tart Linux lane (e.g. `ghcr.io/cirruslabs/ubuntu:latest`)          |
| `KINHIN_E2E_HOST=1`                                 | Turn on the host lane (jobs run on this Mac, in the sandbox's work dirs)       |
| `KINHIN_E2E_GITHUB_TOKEN`, `KINHIN_E2E_GITHUB_REPO` | Turn on the GitHub lane against a **throwaway** repository                     |
| `KINHIN_E2E_KEEP=1`                                 | Keep the sandbox directories (config, logs) of a failed run                    |
| `KINHIN_E2E_GITEA_IMAGE`, `_FORGEJO_IMAGE`, `_GITLAB_IMAGE` | Override the pinned forge images                                       |

A run that is killed (a closed terminal, a `pkill` from another session, a sleeping Mac) can leave a daemon, forge
containers and `/tmp/ke2e-*` sandboxes behind. `scripts/e2e.sh` sweeps those before it starts and again when it exits,
and `scripts/e2e-sweep.sh` does the same on its own. It only touches things the suite created (sandboxes named `ke2e-*`,
containers named `ke2e-*` or built from a `ke2e-*` image, and daemons recorded in a sandbox's `daemon.pid`), and does
nothing while another run is active.

### What the machine needs

- Apple Silicon, with **Docker** (Docker Desktop, OrbStack or Colima), and/or the `container` CLI, and/or Tart.
  Lanes whose runtime is missing are skipped.
- **No other kinhin fleet running.** kinhin adopts every `kinhin-*` container or VM its runtimes list, whoever made it,
  so a lane started next to a real fleet could adopt (and delete) its instances. `Lane.start` refuses to run while any
  `kinhin-*` instance exists and names them; stop the other fleet, or remove a killed run's leftovers, first.
- Plenty of free disk (the Docker VM filled up once during this work and silently broke pulls and container starts). Forge images, runner images and the Docker VM's own disk add up; a full Docker VM makes pulls
  fail with `no space left on device`.
- A LAN address. Containers cannot reach the host's `localhost`, so the suite addresses its forges by the Mac's
  address (plain http, with `allow_insecure_http: true` in the sandbox config).
- It cannot run in `kinhin-xcode` CI: that runner is itself a Tart VM, and Apple Silicon does not nest VMs. See
  [`.github/workflows/e2e.yml`](../.github/workflows/e2e.yml): run by hand (`workflow_dispatch`) on a dedicated Mac
  labelled `kinhin-e2e`, never on pull requests. The nightly and weekly schedules are switched on once that Mac exists
  (beta-2); until then the T2 and T3 cadences below are the target, and the tiers run locally with `scripts/e2e.sh`.

## The tiers

| Tier | What                                                                              | Where                                 | Cadence             |
| ---- | --------------------------------------------------------------------------------- | ------------------------------------- | ------------------- |
| T0   | The fake-based suite (`scripts/check.sh`)                                         | `kinhin-xcode` CI                     | Every PR            |
| T1   | Quick: CLI, security, coverage guards (real binary, sandboxed filesystem)         | Anywhere the binary builds            | On demand           |
| T2   | Local: Gitea and Forgejo in Docker; Docker and Apple container runtimes           | The e2e Mac                           | Nightly             |
| T3   | Full: + GitLab CE and every toolchain                                             | The e2e Mac                           | Weekly              |
| T4   | Credential-gated: GitHub (and, when fixtures exist, the other hosted forges)      | The e2e Mac, secrets from CI          | Weekly, if secrets  |

## What is checked

**`LifecycleTests`** (forge × runtime, from `LifecycleCase.all`: every `ForgeKind` × every `RuntimeKind`). A job is
pushed to a real forge. The test then asserts, with the forge as judge:

1. The job ran **inside the guest**: it opens a "proof" issue whose body is the guest's `uname -s`, hostname and working
   directory, and the kernel matches the runtime (`Linux` for containers and Tart Linux, `Darwin` for Tart macOS) and
   the hostname is not this Mac's. In host mode, where it is this Mac, the job must have run in its instance's work
   directory inside the sandbox.
2. The instance that ran it is **deleted** afterwards, within the forge's exit rule (deregistration or idle grace).
3. The forge **no longer lists** the runner (kinhin deregistered what it spawned).
4. The access token is **absent from kinhin's log** and the daemon is still alive.
5. A job that **fails** is reported failed by the forge, produced no proof, and a good job afterwards still runs.

**`FleetBehaviorTests`**: pause/resume (a paused fleet starts nothing, even after a runner is killed), a `SIGKILL`ed
daemon whose orphan runner is reconciled away by the next daemon, the `max_runners` ceiling with two concurrent jobs,
a job longer than the idle grace on every Gitea/Forgejo lane, a picked-up job not being scaled down under it with no
floor (Gitea 1.26, Forgejo, GitLab), a forge that hangs mid-job (`docker pause` for 45 s) costing neither the runner
nor the job, the Tart `warm_pool` (a warm VM waits, the next job claims it), and a broken image backing the fleet off
instead of crashing. It also pins a known limitation ([below](#known-limitations)) with `withKnownIssue`, which fails
loudly the day the limitation is fixed.

**`FeatureTests`**: on a busy fleet, `status --json` shows the busy instance, `pipeline --json` lists it, `logs`
shows the daemon's history with no token, and `requeue`/`skip` are refused clearly on a forge without a queue API.
Routing precedence with two pools (Docker default, Apple container by repo route): a repo route beats the default on
Gitea and Forgejo; the workflow route is pinned as a known issue.

**`CLITests`**: version and exit codes (usage 2, config 3), `--json` errors, `config init` on a pristine machine,
`config migrate`, the account lifecycle, `doctor` (and a support bundle with no token in it), runtimes and routes,
read-only inventory commands, toolchain detection, `workflow test` and `workflow route`, `reset`, and an MCP
handshake over stdio.

**`SecurityTests`** (from [security.md](security.md)): support directory, config, log directory, log file and daemon
socket are owner-only; plain http to a remote forge is refused unless opted in (loopback is allowed); a host route
needs `--consent`; tokens never appear in command output or the log.

**`ToolchainTests`**: `kinhin bench toolchains --thorough` cold-installs, verifies and runs a workload for tools in a
real guest on Docker, Apple container and Tart Linux (a smoke set by default, every one of which must actually run;
the whole catalog with `KINHIN_E2E_TOOLCHAINS=full`), failing on any failed row or any skip without a reason; and a
real runner job on every guest runtime that runs `kinhin-toolchain install node@22` and proves it.

**`CoverageTests`** keep the suite honest as kinhin grows. They need no infrastructure:

- every forge in `kinhin auth set --help` must be classified in `CoverageTests.forges` as live, gated or waived with a
  reason, so adding a forge fails here until someone decides how it is tested;
- every runtime `kinhin runtimes route add` accepts must have a `RuntimeKind` (Tart twice: macOS and Linux guests), so
  a new runtime joins the forge × runtime matrix or fails here;
- every command in `kinhin help` must map to a test or a stated reason in `CoverageTests.commands`, and no entry may
  name a command that no longer exists;
- every command must answer `--help` with exit 0.

## Adding a forge

Follow [adding-a-forge.md](adding-a-forge.md), then:

1. Add a `ForgeFixture` in `Tests/E2E/Sources/E2ESupport/` (see `GiteaFixture`): start a throwaway server, mint a
   token, create a repository, push workflows, and report the proof issue, run statuses and registered runners from
   the forge's own API.
2. Add a case to `ForgeKind` and to the `switch` in `Lane.start`.
3. Classify it in `CoverageTests.forges`. If it cannot run locally, mark it gated or waived and say why.

## Known limitations

- **Gitea 1.24 and older show no queued job until a runner exists.** The task API lists a task only after a runner
  asks for it, so with `min_runners: 0` kinhin never sees the work. The suite runs those versions with
  `min_runners: 1` (a warm runner) and pins the blind spot in `FleetBehaviorTests.queuedJobIsSeenWithoutAFloor`, which
  expects it as a known issue on Gitea 1.24.
- **A `min_runners` floor lands in the default pool.** Host lanes therefore run without one (Gitea 1.26, Forgejo,
  GitLab), since a host route can never be the default.
- **Workflow routes never match on Gitea or Forgejo.** Neither queue endpoint names a job's workflow (a Gitea 1.26 job
  carries only its name, labels, branch, commit and URLs; the run carries the workflow *file*, not its `name:`), so an
  `owner/repo@Workflow` route is ignored and the repo route or labels decide. Pinned in
  `FeatureTests.routesWinInPrecedenceOrder`. Repo routes work.
- **Gitea 1.25+ and Forgejo 11+ do not have that limit.** kinhin reads `/actions/jobs?status=queued` (Gitea; a job
  nobody has picked up is `queued`, and `waiting` matches nothing) and `/actions/runners/jobs?labels=` (Forgejo; the
  labels are the runner's label set). Verified live with no floor on Gitea 1.26.4 and Forgejo 11. Gitea 1.25.5 listed
  the same job on the same endpoint; the no-floor lifecycle has not been run on 1.25 itself.

## Status

What has actually been run, so the table does not claim more than it checked (2026-10-10):

| Lane                                                      | Status                                                                     |
| --------------------------------------------------------- | -------------------------------------------------------------------------- |
| Quick tier (CLI, security, coverage)                      | Run, passing                                                               |
| Gitea, Forgejo, GitLab CE × Docker, Apple container       | Run, passing (lifecycle, failing job)                                      |
| Gitea, Forgejo, GitLab CE × Tart Linux (`ubuntu`)         | Run, passing (lifecycle, failing job; long job on Gitea/Forgejo)           |
| Gitea, Forgejo, GitLab CE × Tart macOS (`macos-tahoe-base`) | Run, passing (lifecycle, failing job; long job on Gitea/Forgejo)         |
| Gitea (1.26), Forgejo, GitLab CE × host                   | Run, passing (lifecycle; long job and failing job on Gitea/Forgejo)        |
| Gitea 1.25                                                | Endpoints probed live; lifecycle **not run**                               |
| Fleet behavior (all tests above)                          | Run, passing                                                               |
| Features (busy-fleet commands, routing precedence)        | Run, passing; workflow routes pinned as a known issue                      |
| Toolchains: bench `--thorough` smoke set                  | Run, passing on Docker, Apple container, Tart Linux; full catalog **not run** |
| Toolchains: per-job `kinhin-toolchain install`            | Run, passing on Docker, Apple container, Tart Linux, Tart macOS            |
| GitHub                                                    | Fixture written, **not run**: needs a throwaway repository and a token     |
| Buildkite, Azure DevOps, Bitbucket                        | Planned forges, not supported yet; the fixture protocol is ready for them  |
| App UI, App Intents, upgrade/migration                    | **Not started** (out of scope of this pass)                                |
