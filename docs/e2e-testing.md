# End-to-end testing

`swift test` runs about 2,300 tests against fakes (`FakeTart`, `FakeSSH`, `FakeGitea`, ...) in two minutes with no VMs
and no network. That keeps the suite fast, but it can only prove kinhin agrees with its own model of a forge or a
runner. The end-to-end (e2e) suite in `Tests/E2E` checks the model against the real thing: a real forge in a
container, a real kinhin daemon, a real runner image, and a job that really runs inside a guest.

It earned its keep on the first day. The first live Gitea job exposed [five defects](#what-the-first-live-runs-found)
that the fakes had been pinning as correct.

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

Narrow the matrix with environment variables:

| Variable                                            | Effect                                                                         |
| --------------------------------------------------- | ------------------------------------------------------------------------------ |
| `KINHIN_E2E_FORGES=gitea,forgejo`                   | Only these forges (`gitea`, `forgejo`, `gitlab`, `github`)                     |
| `KINHIN_E2E_RUNTIMES=docker,appleContainer`         | Only these runtimes                                                            |
| `KINHIN_E2E_HEAVY=1`                                | Include GitLab CE (several GB, minutes to boot)                                |
| `KINHIN_E2E_TOOLCHAINS=full`                        | The whole toolchain catalog instead of the smoke set                           |
| `KINHIN_E2E_TART_BASE=<local macOS tart image>`     | Turn on the Tart macOS lane (bakes a derived image from this one)              |
| `KINHIN_E2E_GITHUB_TOKEN`, `KINHIN_E2E_GITHUB_REPO` | Turn on the GitHub lane against a **throwaway** repository                     |
| `KINHIN_E2E_KEEP=1`                                 | Keep the sandbox directories (config, logs) of a failed run                    |
| `KINHIN_E2E_GITEA_IMAGE`, `_FORGEJO_IMAGE`, `_GITLAB_IMAGE` | Override the pinned forge images                                       |

### What the machine needs

- Apple Silicon, with **Docker** (Docker Desktop, OrbStack or Colima), and/or the `container` CLI, and/or Tart.
  Lanes whose runtime is missing are skipped.
- Plenty of free disk (the Docker VM filled up once during this work and silently broke pulls and container starts). Forge images, runner images and the Docker VM's own disk add up; a full Docker VM makes pulls
  fail with `no space left on device`.
- A LAN address. Containers cannot reach the host's `localhost`, so the suite addresses its forges by the Mac's
  address (plain http, with `allow_insecure_http: true` in the sandbox config).
- It cannot run in `kinhin-xcode` CI: that runner is itself a Tart VM, and Apple Silicon does not nest VMs. See
  [`.github/workflows/e2e.yml`](../.github/workflows/e2e.yml): a nightly local tier and a weekly full tier on a
  dedicated Mac labelled `kinhin-e2e`, never on pull requests.

## The tiers

| Tier | What                                                                              | Where                                 | Cadence             |
| ---- | --------------------------------------------------------------------------------- | ------------------------------------- | ------------------- |
| T0   | The fake-based suite (`scripts/check.sh`)                                         | `kinhin-xcode` CI                     | Every PR            |
| T1   | Quick: CLI, security, coverage guards (real binary, sandboxed filesystem)         | Anywhere the binary builds            | On demand           |
| T2   | Local: Gitea and Forgejo in Docker; Docker and Apple container runtimes           | The e2e Mac                           | Nightly             |
| T3   | Full: + GitLab CE and every toolchain                                             | The e2e Mac                           | Weekly              |
| T4   | Credential-gated: GitHub (and, when fixtures exist, the other hosted forges)      | The e2e Mac, secrets from CI          | Weekly, if secrets  |

## What is checked

**`LifecycleTests`** (forge × runtime, from `LifecycleCase.all`). A job is pushed to a real forge. The test then
asserts, with the forge as judge:

1. The job ran **inside the guest**: it opens a "proof" issue whose body is the guest's `uname -s` and hostname, and
   the kernel matches the runtime (`Linux` for containers, `Darwin` for Tart) and the hostname is not this Mac's.
2. The instance that ran it is **deleted** afterwards, within the forge's exit rule (deregistration or idle grace).
3. The forge **no longer lists** the runner (kinhin deregistered what it spawned).
4. The access token is **absent from kinhin's log** and the daemon is still alive.
5. A job that **fails** is reported failed by the forge, produced no proof, and a good job afterwards still runs.

**`FleetBehaviorTests`**: pause/resume (a paused fleet starts nothing, even after a runner is killed), a `SIGKILL`ed
daemon whose orphan runner is reconciled away by the next daemon, the `max_runners` ceiling with two concurrent jobs,
and a broken image backing the fleet off instead of crashing. It also pins a known limitation
([below](#known-limitations)) with `withKnownIssue`, which fails loudly the day the limitation is fixed.

**`CLITests`**: version and exit codes (usage 2, config 3), `--json` errors, `config init` on a pristine machine,
`config migrate`, the account lifecycle, `doctor` (and a support bundle with no token in it), runtimes and routes,
read-only inventory commands, toolchain detection, `workflow test` and `workflow route`, `reset`, and an MCP
handshake over stdio.

**`SecurityTests`** (from [security.md](security.md)): support directory, config, log directory, log file and daemon
socket are owner-only; plain http to a remote forge is refused unless opted in (loopback is allowed); a host route
needs `--consent`; tokens never appear in command output or the log.

**`ToolchainTests`**: `kinhin bench toolchains` installs, verifies and runs a workload for tools in a real guest on
each runtime (a smoke set by default, the whole catalog with `KINHIN_E2E_TOOLCHAINS=full`), failing on any failed row
or any skip without a reason; and a real runner job that runs `kinhin-toolchain install node@22` and proves it.

**`CoverageTests`** keep the suite honest as kinhin grows. They need no infrastructure:

- every forge in `kinhin auth set --help` must be classified in `CoverageTests.forges` as live, gated or waived with a
  reason, so adding a forge fails here until someone decides how it is tested;
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

- **Gitea 1.24 and Forgejo 11 show no queued job until a runner exists.** Their task API lists a task only after a
  runner asks for it, so with `min_runners: 0` kinhin never sees the work. The suite runs those forges with
  `min_runners: 1` (a warm runner) and pins the blind spot in `FleetBehaviorTests.giteaWithoutFloorIsBlind`. Gitea
  1.25 and later have `/actions/jobs?status=waiting` (probed live on 1.25.5 and 1.26.4), which kinhin does not use yet; using it would remove the floor there.

## What the first live runs found

Running one real job end to end exposed these. Each now has a fix and a regression test.

1. **`kinhin start` crashed on macOS 27.** It parked the main thread with `dispatchMain()`, which libdispatch now
   traps on when called from a main-queue block. It parks on a continuation instead.
2. **Gitea/Forgejo registration ran the wrong program.** In containers and Tart VMs the script ran the GitHub
   runner's `./config.sh` and `run.sh`; on macOS VMs it ran `gitea-runner run` and `gitea-runner remove`, which the
   runner does not have (its CLI is `register --no-interactive` then `daemon`). Three unit tests had been pinning the
   wrong scripts, one with a comment saying so.
3. **The Gitea pool ignored its own labels**, so a Docker pool never advertised `kinhin-docker`, and `runs-on:
   kinhin-docker` could not match.
4. **`kinhin config init` failed on a pristine machine** ("The folder "config.yaml" doesn't exist") and wrote the
   config world-readable.
5. **Gitea 1.26 could not be used at all.** It dropped `GET` for the runner registration token (404 "Runner not found";
   only `POST` works), and kinhin sent `GET`. The client now falls back to `POST`. Found by probing 1.24, 1.25 and 1.26
   and verified with the lifecycle suite on 1.26.4.
6. The Gitea blind spot above, which is a limitation rather than a defect.

## Status

What has actually been run, so the table does not claim more than it checked:

| Lane                                  | Status                                                                      |
| ------------------------------------- | --------------------------------------------------------------------------- |
| Quick tier (CLI, security, coverage)  | Run, passing                                                                |
| Gitea 1.24 and 1.26 on Docker         | Run, passing (lifecycle, failing job)                                       |
| Gitea 1.25                            | Endpoints probed live; lifecycle **not run**                                |
| Forgejo on Docker, Gitea/Forgejo on Apple container, fleet behavior, toolchains | See the latest run notes in the pull request |
| GitLab CE                             | Fixture written, **not run**: the first image pull ran the Docker VM out of disk (since cleared) |
| GitHub                                | Fixture written, **not run**: needs a throwaway repository and a token       |
| Buildkite, Azure DevOps, Bitbucket    | Waived: hosted-only control planes; the fixture protocol is ready for them   |
| Tart macOS lane                       | Wired (`KINHIN_E2E_TART_BASE`), **not run**                                  |
