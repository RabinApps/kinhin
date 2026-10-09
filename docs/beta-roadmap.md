# Beta roadmap to v0.1.0

What is verified today, and the milestones between the current beta and the **v0.1.0** release.

[← Back to README](../README.md) · [Forge support](forges.md#what-has-been-tested)

kinhin is in beta (`v0.0.1-beta-1`). The goal of the beta is to turn "unit-tested against fakes" into "run against a
real server" for every forge and runtime we ship. Milestones are ordered by what has to be true, not by date.

## Where we are

| Area | State |
| ---- | ----- |
| GitHub Actions + Tart macOS VMs | Live-tested |
| apple/container runtime (Linux jobs) | Live-tested |
| Gitea Actions + Docker (Gitea 1.24) | Live-tested by the end-to-end suite |
| Forgejo, GitLab, Buildkite, Azure DevOps, Bitbucket | Unit-tested only (stubbed HTTP, fake shells); never run against a real server |
| Docker runtime | Live-tested with Gitea only |
| Tart Linux and host runtimes | Unit-tested only |
| In-app updater | Not yet exercised against a published release |
| Telemetry | None |

The detailed results of each test pass are kept in the [beta test log](plans/beta-test-log.md).

## Milestones

### beta-1: first public beta (current)

- GitHub Actions with Tart macOS VMs verified end to end.
- Menu bar app, CLI and LaunchAgent daemon released, signed and notarized.
- Docs, forge reference and the forge-report issue template published.

### beta-2: first real-server runs

- Run Gitea, Forgejo and GitLab (gitlab.com and a self-managed instance) against real servers and fix API-shape surprises.
- Exercise the in-app updater against a published release.
- Verify Linux jobs on Docker (apple/container is already live-tested).

**Exit:** each of those forges has a passing real run recorded in [what has been tested](forges.md#what-has-been-tested).

### beta-3: remaining forges and runtimes

- Run Buildkite, Azure DevOps and Bitbucket against real accounts.
- Run the remaining runtimes (Docker, Tart Linux, host) for real.
- Multi-account and mixed-forge fleets on one shared pool.

**Exit:** every shipped forge and runtime is either live-tested or clearly labeled experimental in the docs.

### rc: hardening

- ThreadSanitizer run is clean (`scripts/tsan.sh`).
- Long-running soak test: scaling up and down, crash and restart recovery, no leaked VMs, containers or registered runners.
- Troubleshooting and security [known limits](security.md#known-limits) reviewed against what beta testers hit.
- Docs read-through against the shipped CLI and app.

**Exit:** no open data-loss, leaked-credential or leaked-runner bugs.

### v0.1.0: full release

- All the exit criteria above are met.
- Signed, notarized release with a working updater path from the last beta.
- Docs snapshot published under the version picker.

## How to help

Run kinhin against a forge or runtime that is still marked untested, then open a
[forge report](https://github.com/RabinApps/kinhin/issues/new/choose) saying whether it worked. Reports are what move a
forge from "unit-tested" to "live-tested".
