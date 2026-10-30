# Beta roadmap to v0.1.0

What is supported today, and the milestones between the current beta and the **v0.1.0** release.

[← Back to README](../README.md) · [Forge support](forges.md#what-has-been-tested)

<!-- docs-sync:begin release-line -->
kinhin is in beta (`v0.0.1-beta-4`).
<!-- docs-sync:end release-line -->

The beta supports **GitHub, Gitea, Forgejo and GitLab CE**; Buildkite, Azure Pipelines and Bitbucket Pipelines follow in
later betas (planned for beta 5). Milestones are ordered by what has to be true, not by date.

## Where we are

| Area | State |
| ---- | ----- |
| GitHub Actions | Supported; live-tested on Tart macOS VMs and apple/container |
| Gitea, Forgejo, GitLab CE | Supported; live-tested on every runtime by the [end-to-end suite](e2e-testing.md) |
| Runtimes: Tart macOS and Linux VMs, apple/container, Docker, host mode | Live-tested |
| Buildkite, Azure Pipelines, Bitbucket Pipelines | Planned (implemented and unit-tested, not supported yet) |
| ThreadSanitizer | Clean (`scripts/tsan.sh`) |
| Long-running soak test | Not done |
| In-app updater | Ships in beta-3; not yet exercised by a published release updating itself (needs the next release) |
| Telemetry | Opt-in OpenTelemetry (off by default; exports only to a server you configure). See [Telemetry](telemetry.md) |

## Milestones

### beta-1: first public beta

- GitHub, Gitea, Forgejo and GitLab CE supported. Gitea, Forgejo and GitLab CE live-tested on every runtime; GitHub on
  Tart macOS VMs and apple/container.
- Menu bar app, CLI and LaunchAgent daemon released, signed and notarized.
- Docs, forge reference and the forge-report issue template published.

### beta-2: hardening the supported forges

- Fixes from beta testers' real projects.
- The GitHub lane of the end-to-end suite running against a throwaway repository.
- The e2e suite running nightly on a dedicated Mac.
- Exercise the in-app updater against a published release.

**Exit:** no open bugs that lose a job or leak a runner on a supported forge.

### beta-3: updater, restart safety and localization

- The in-app updater installs updates itself (Sparkle, EdDSA-signed feed).
- A restart no longer registers a VM again while its runner is still on the forge.
- Ollama as a healing advisor, camera and karaoke captions for videos, and the app in seven more languages.
- Azure Pipelines labeled experimental.

### beta-4: telemetry, macOS 27 images and reliability (current)

- Opt-in OpenTelemetry: metrics, traces and logs over OTLP, a Prometheus endpoint, `kinhin telemetry status` and a menu bar card.
- The macOS 27 Golden Gate base images and digest-pinned base images.
- Install and reliability fixes: the daemon's LaunchAgent path, `vm.cpu` and `vm.memory_gb` on Tart, warm-pool counting, and
  every running job shown on multi-runner VMs.
- Linux runners (Apple container and Docker) no longer carry the `macos` label.

The Buildkite, Azure Pipelines and Bitbucket Pipelines work promised for this beta did not make it and moves to beta 5.

### beta-5: more forges

- Buildkite, Azure Pipelines and Bitbucket Pipelines run against real accounts in the end-to-end suite, and become
  supported one by one as they pass.
- Multi-account and mixed-forge fleets on one shared pool.
- Register the dedicated `kinhin-e2e` Mac, run the GitHub lane, and turn on the nightly end-to-end run.

**Exit:** every forge the docs call supported is live-tested; the rest are clearly labeled planned.

### rc: hardening

- ThreadSanitizer still clean (`scripts/tsan.sh`).
- Long-running soak test: scaling up and down, crash and restart recovery, no leaked VMs, containers or registered runners.
- Troubleshooting and security [known limits](security.md#known-limits) reviewed against what beta testers hit.
- Docs read-through against the shipped CLI and app.

**Exit:** no open data-loss, leaked-credential or leaked-runner bugs.

### v0.1.0: full release

- All the exit criteria above are met.
- Signed, notarized release with a working updater path from the last beta.
- Docs snapshot published under the version picker.

## How to help

Run kinhin on your own projects with a supported forge, then open a
[forge report](https://github.com/RabinApps/kinhin/issues/new/choose) saying whether it worked.
