# Changelog

## Unreleased

<!-- changelog: entries for the next release go here -->

**Added**

- `kinhin video init | list | build`: make a narrated video of your own product from `.kinhin/videos/*.yml`, with no copy of the
  video suite. It runs a published container image (Apple `container` or Docker) against your repository; `--on-fleet` builds on a
  runner through a generated GitHub workflow. Music, captions, themes and formats are config. See
  [docs/videos-for-your-project.md](docs/videos-for-your-project.md).
- **Make a Video…** on the app's Fleet tab: choose a repository, create and build a video with live output, and search and add music, with
  the same code as `kinhin video`.
- `kinhin video music` can use your own Openverse application (`KINHIN_OPENVERSE_CLIENT_ID` and `KINHIN_OPENVERSE_CLIENT_SECRET`) for a higher search limit.
- `kinhin video theme list | new`, and your own theme files in `.kinhin/videos/themes/` (they can extend a built-in theme and change only
  what they want).
- `kinhin video music search | preview | add | list`: find CC0 and public-domain music (Openverse, plus the tracks built into the image),
  download it into `.kinhin/videos/music/` with its source and license, and set `music:` in a video's config without touching
  the rest of the file. `--license cc-by` also offers CC BY tracks and writes their credit line.

**Changed**

- The video image's base (`video/Dockerfile`, renamed from `Containerfile` so Dependabot can read it) is pinned by digest, and Dependabot
  now keeps it and `video/package.json` current.
- A repo's per-project config now lives at `.kinhin/config.yml`. The older `.kinhin.yml` is still read when the new file is
  absent, and `kinhin toolchains detect --write` writes the new path.
- Install docs for Linux jobs: apple/container (recommended, `kinhin setup repair container`) and Docker
  (`kinhin setup repair docker`), in [docs/install.md](docs/install.md#installing-a-linux-runtime).

**Fixed**

- The apple/container install hints now include `--enable-kernel-install`. Without it, `container run` fails with
  "default kernel not configured".

## v0.0.1-beta-1

First public beta. kinhin watches your CI queue and, for each queued job, starts a fresh VM or container on your Apple
Silicon Mac, registers a one-job runner, lets it run, then deletes it. Free, Apache-2.0, no telemetry.

**Supported forges:** GitHub Actions, Gitea Actions, Forgejo Actions and GitLab CE. Buildkite, Azure Pipelines and
Bitbucket Pipelines are planned for a later release; the app marks them untested.

**Runtimes:** Tart macOS and Linux VMs, apple/container, Docker, and an opt-in host mode with no isolation (behind an
explicit consent flag).

**What is in it**

- **Autoscaling.** Ephemeral runners between `min_runners` and `max_runners`, capped by what this Mac can hold after
  reserving headroom (`kinhin doctor` shows the number). `runners_per_vm` packs several jobs into one VM; `warm_pool: N`
  keeps booted, unregistered Tart VMs ready to claim.
- **Routing.** Pools per runtime with their own labels; route by repository, workflow or `runs-on:` label.
  `kinhin workflow route` edits a workflow's `runs-on:` for a runtime.
- **Toolchains.** Bake tools into the image, pin them per repository (`.kinhin.yml`), or install them per job, with an
  opt-in shared cache.
- **App, CLI and daemon.** A menu bar app with a setup wizard, a full CLI, and a LaunchAgent daemon on one engine and one
  config. Tokens live in the Keychain. Every read command has `--json`; `kinhin mcp` is an MCP server; seven agent
  skills ship in `skills/`.
- **Operating.** `status`, `pipeline`, `logs` (redacted), `pause`/`resume`, `requeue`/`skip`, `cleanup`, `doctor`
  (`--check-tokens`, `--bundle`), `reset`, and `kinhin bench` for boot and workload timings on this Mac.
- **Workflows locally.** `kinhin workflow test` runs a GitHub Actions workflow's scripts on this Mac and reports
  `partial` when it had to skip something.
- **Strict config.** Unknown keys are an error with a suggestion; `kinhin config validate` and `kinhin config migrate`.
- **Open-source projects.** A guide (`docs/open-source.md`) to keeping fork pull requests off kinhin and hardening
  the fleet for public repositories. Jobs whose forge does not say whether they come from a fork (GitHub scale-set
  jobs, Gitea and Forgejo) get the fork treatment: no shared cache, and `.kinhin.yml` from the default branch.
- **Move a setup to another Mac.** `kinhin config export` and `kinhin config import` copy the config (never tokens or
  images), validate before writing, keep the old config as `config.yaml.bak`, and list the tokens to store on the new
  Mac.

**Tested for real:** GitHub Actions on Tart macOS VMs and apple/container, by hand. Gitea 1.24 and 1.26, Forgejo 11 and
GitLab CE 18.4 on every runtime, by the end-to-end suite (`scripts/e2e.sh`), including crash recovery, the concurrency
cap, pause and resume, forge outages, the warm pool, routing and toolchain installs.

**Not yet exercised:** the in-app updater against a published release (this is the first one).

**Fixed before release**

- GitHub scale-set mode acquires each available job (`acquirejobs`), as GitHub's listener contract requires, and logs
  every job event (`[scaleset] message <id>: …`).
- A scale-set session GitHub drops (after a network outage) is replaced instead of refreshed forever.

**Known limitations**

- Gitea 1.24 and older report no queued job until a runner exists: set `min_runners: 1`.
- Workflow routes (`owner/repo@Workflow`) do not match on Gitea or Forgejo, whose APIs do not name a job's workflow.
- On Forgejo, which has no runner list, a job's instance can outlive the job while another job runs in the same
  repository.
- kinhin adopts every `kinhin-*` VM or container on the Mac as its own.
- Apple allows two macOS guest VMs at once on a Mac.
- GitHub scale sets: with `runners_per_vm > 1` a second job waits for the first instead of using an idle runner in the
  same VM. Use `runners_per_vm: 1` and a Tart pool that holds two VMs (`docs/forges/github.md`).
- Restarting the daemon while a job runs can delete that job's VM after recovery. Restart when the fleet is idle.

More in [docs/security.md](docs/security.md#known-limits). The path to **v0.1.0** is in
[docs/beta-roadmap.md](docs/beta-roadmap.md).
