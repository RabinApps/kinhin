# Changelog

## Unreleased

<!-- changelog: entries for the next release go here -->

**Added**

- The macOS 27 Golden Gate base images (`macos-golden-gate-base`, `-vanilla`, `-xcode`) join the curated base-image
  picker, and any `ghcr.io/cirruslabs/macos-*` reference pinned by `@sha256:` digest is accepted too: the pin names
  exact, immutable bits, so it stays servable even after its tag is retired. The base-image refusal now says what
  is acceptable, including `kinhin image digest <reference>` for printing the pin, instead of only failing. A local
  Tart VM name is no longer warned about as a mutable tag: without a registry there is nothing to drift. See
  [docs/runtimes.md](docs/runtimes.md#choosing-the-base-image).
- `kinhin config validate [FILE]` checks a named config file instead of this Mac's default one — useful before
  pointing a fleet at the file, in CI, or for agent review of a proposed config. The command honors `--` before the
  file name (so `kinhin config validate -- -broken.yaml` parses) and rejects extra operands.

**Fixed**

- `kinhin daemon install` wrote the path it was found by into the daemon's LaunchAgent: a bare `kinhin` resolved
  through PATH became `<cwd>/kinhin`, which launchd could not run at login. The path now comes from the running
  binary itself (`Bundle.main`/`_NSGetExecutablePath`, symlinks resolved), and the install uses `launchctl
  bootstrap` and verifies with `launchctl print` that the agent is actually running — a daemon that exits
  immediately is reported as a failure instead of a silent success, and `launchctl print`'s annotated exit codes
  (`78: EX_CONFIG`) read as the failure they are: a code that cannot be parsed is not called healthy. Re-run
  `kinhin daemon install` on a Mac whose daemon does not start.
- `warm_pool: 1` could keep two VMs of an image: while the first pooled VM was still cloning or booting the scale
  plan could not see it, so the next reconcile pass started another. Pooled VMs in flight now count toward the
  pool's target — and toward the fleet's global and per-runtime caps — so queued jobs wait for the clone to land
  instead of the spawn going past the limit. See [docs/scaling.md](docs/scaling.md#warm-pool).
- `vm.cpu` and `vm.memory_gb` were silently ignored on Tart runners: the clone never issued `tart set`. The vCPU
  count and memory are now set on the clone before its first boot, for runner, warm-pool and named-image clones
  alike, a failed `tart set` fails the spawn instead of booting an unconstrained VM, and a clone interrupted
  before its first boot resumes with its sizing and a start instead of waiting for an IP until the boot timeout.
- An image that could not be deleted aborted the whole `image delete` or `prune` run, including the digest twin hit
  because its tag twin was just deleted. A missing image counts as deleted, the run continues past the failures,
  every failure is reported together at the end, and an image whose deletion failed keeps its inventory record for
  the next try instead of vanishing from the listing; the image store is cleaned up as normal.
- The reachability hint after a failed image bake named the host's virtualization networking for any kind of
  timeout. The hint appears only when the failure excerpt is an SSH connection failure; a guest script timing out
  on an outside service no longer sends you re-checking the host.
- The `kinhin runtimes` budget bar rounded percentages at the wrong step, printing only edge values. It rounds
  after scaling now.

**Changed**

- Apple-container and Docker runners no longer advertise the fleet's `macos` label: their guests run Linux, and a macOS
  job started there would never finish (each Linux runtime keeps `kinhin-container`/`kinhin-docker`, the architecture
  label and — for containers — the `container.labels:` entries). A pool that must speak other fleet labels can drop the
  inheritance  with `fleet_labels: false` under `container:` or `docker:` (replace-not-add: the pool then registers with
  the marker and that section's own labels alone — and keeps the architecture label of the guest it actually
  runs, so an amd64 Docker VM advertises `x64` rather than the inherited `arm64`). Configs whose workflows
  targeted a Linux runtime with `runs-on: […, macos]` must switch to the marker label.
- The default `image:` can carry runner labels via top-level `image_labels:` (same rules as a named `images:` entry's
  `labels:`), and a Linux default base keeps macOS jobs off its runners by stripping `macos` — the behavior named
  Linux images already had, extended to the default image, and the same rule reads the image's own labels: a
  `macos` word in a Linux image's `labels:` is stripped too, so it cannot put the runner back into the macOS
  pool.

## v0.0.1-beta-3

**Added**

- The healing agent can use [Ollama](https://ollama.com) with your own models: `healing: {ai: ollama, ollama: {model: …}}`.
  An optional `fast_model` (for example `clef-flash` or `nimble`, Ollama's decision models) is asked first, and the LLM
  answers when it is not confident. Traffic goes to `healing.ollama.host`, which is this Mac by default; any other host
  must be `https`, and it then receives the redacted problem and log lines. See [docs/healing.md](docs/healing.md#the-ollama-advisor).
- Videos can move a camera over a recording: a `device` or `terminal` scene's `camera` zooms and pans, `focus` spotlights part of the
  screen and `cursor` adds a pointer with click rings, all from positions in the recording. A new `karaoke` caption style lights each
  word as it is spoken, and `transition` (`dissolve`, `push`, `slide`, `wipe` or `circle`, per project or per scene) replaces the
  fade between scenes without moving the voice. Nothing changes for a video that does not use them. See [docs/video-config.md](docs/video-config.md#camera-on-recordings).
- An adapter can name regions of its clips (`targets`), and the camera, spotlight and cursor can point at a name instead of
  coordinates, so a redesigned screen is fixed once. `speed` can be a list of segments with eased changes (speed ramps) and works in every
  frame. A new `split` scene plays two recordings side by side, or one above the other in a vertical frame, each with its own camera,
  speed and a `delay`. See [docs/video-config.md](docs/video-config.md#speed-ramps).
- Video builds reuse more. The voice of each sentence and each framed recording are kept in `.kinhin/videos/.cache/` and used again
  while nothing that shapes them has changed, so a one-line edit no longer speaks and frames the whole video again. The WebM and the
  temporary per-scene encodes are faster, and every build prints how long each step took. `kinhin video build --scene app,outro`
  builds only those scenes as a quick preview, and `--watch` rebuilds when your video files change. See
  [docs/videos-for-your-project.md](docs/videos-for-your-project.md#faster-rebuilds).
- `kinhin video record --pointer` writes where the pointer was and where it clicked beside the clip, and a `device` scene's
  `autoZoom` turns those clicks into camera moves. The picture still never shows the pointer. `captions.burn` can be a list of
  formats (`["9:16", "1:1"]`); kinhin's own adapter now burns captions in the vertical and square cuts and leaves 16:9 clean,
  while other projects keep burning them in every format.
- The menu bar app is translated into Spanish, Japanese, German, Hebrew, Arabic, Italian and French, and follows the macOS
  language. The translations are first drafts awaiting native-speaker review, so please report wrong or awkward wording. The
  CLI, its output and the docs stay English. Disclosure arrows now mirror in right-to-left languages.

**Fixed**

- A classic (non-ephemeral) runner in an Apple container or Docker container is registered again after a restart when the forge no longer has it. Stopping the container (host reboot, `container system stop`) kills the agent inside, and kinhin used to watch the instance as `ready` with no runner until you deleted it. Registration also stops an agent left from an earlier registration first.
- `kinhin image digest` and the app's Pin button no longer fail with `registry answered HTTP 404` for Cirrus Labs images such as `macos-sequoia-base:latest`. The registry request now names every manifest type, not only image indexes.
- A new VM no longer waits the whole `vm_boot_timeout` (about five minutes) before kinhin tries SSH when macOS Local Network privacy blocks its port 22 probe. After 15 seconds kinhin tries SSH anyway and logs why. The app now declares a Local Network usage description. See [Troubleshooting](website/guide/troubleshooting.md).
- `kinhin doctor` no longer calls Command Line Tools outdated when they only trail macOS by a patch release (CLT 27.0.0 on macOS 27.0.1).
- `kinhin auth list --json` now exists, and `kinhin auth status --account NAME --json` reports only that account instead of every forge.
- Azure DevOps: kinhin warns at start-up when the agent pool has no agents, because Azure then rejects labelled jobs instead of queueing them. The Azure DevOps page documents the offline placeholder agent that fixes it. Azure is now described as experimental rather than planned; it has had live smoke runs, not real application builds.
- A restart no longer registers a VM again while its runner is still on the forge, which could fail a job running on it. A runner the forge still has is watched; a VM with no runner is registered as normal. A VM whose forge cannot be asked is held, shown by an `adoption` alert, until it can be; a VM whose account has no forge attached is held the same way and removed after one hour; a VM whose account was removed from the config is released at once. Forges with no runner list, and partly registered VMs, have their own rules. See [docs/scaling.md](docs/scaling.md#restarts).

**Changed**

- The in-app updater now installs updates itself. It uses [Sparkle](https://sparkle-project.org): kinhin downloads the new release, checks its EdDSA signature, replaces the running app and relaunches. Before, it only opened the DMG for a manual drag into Applications. See [Updates and installs](docs/install.md#how-updates-and-installs-are-verified).
- Update checks run once a day through Sparkle, and the hourly check is gone. Settings → App shows **Install Update…** when a release is waiting.
- After an upgrade, the app restarts a daemon that is still running the previous build, so the daemon runs the new binary. This interrupts any jobs that daemon is running.

**Upgrading**

- Builds before this release still open the DMG, so update once by hand. Updates after that install automatically.

## v0.0.1-beta-2

**Added**

- `kinhin video record <app or title>` records one window of your app as a clip, with the mouse pointer left out, for a video's app scene. `--list-windows` shows what can be recorded and `--window ID` picks one. It needs Screen Recording permission for your terminal once. See [docs/video-adapters.md](docs/video-adapters.md#recording-clips).
- The healing agent: kinhin fixes the fleet problems it safely can on its own (a warm VM deleted out of band, a toolchain
  cache filling the disk, a detached account, a stopped Apple container system) and asks before anything destructive
  (pruning images, reinstalling a runtime). `kinhin heal` shows the journal, and `kinhin heal approve|dismiss ID` acts
  on it. The app's Diagnostics sheet has a Healing card, and a notification fires when a fix succeeds. Configure it under
  `healing:`. On macOS 26 with Apple Intelligence, the on-device Apple Intelligence model can pick from the allowed fixes
  for problems no rule covers. See [docs/healing.md](docs/healing.md).
- `warm_pool` on an `images:` entry keeps booted, unregistered VMs of that image ready, so jobs routed to it (for example
  `xcode`) skip the clone and boot. The top-level `warm_pool` still covers `image:`; the two share `max_runners`.
- "VMs kept ready" controls: each image in the "More images" card has a stepper for its warm pool, and the Capacity view
  has a row for the base image's. Changes are saved after the stepper settles.
- `kinhin mobile init --ci` and `kinhin video init --workflow --ci` write the pipeline for GitLab CI, Gitea and Forgejo
  Actions, Bitbucket Pipelines, Azure Pipelines or Buildkite, as well as GitHub Actions. The system is detected from the
  repository when the flag is left out. Mobile releases outside GitHub run one script, `.kinhin/mobile-release.sh`. See
  [docs/mobile-fastlane.md](docs/mobile-fastlane.md#other-ci-systems) and
  [docs/videos-for-your-project.md](docs/videos-for-your-project.md#building-on-a-runner-or-in-ci).
- `kinhin mobile init` adds a `screenshots` lane: `snapshot` for iOS UI tests and `screengrab` for Android instrumented tests, with optional device frames and optional upload. See [docs/mobile-screenshots.md](docs/mobile-screenshots.md).
- `kinhin mobile init` scaffolds fastlane release setup for iOS, Android, Flutter, React Native and
  native projects with lanes, a pinned Gemfile and a manual `mobile-release` workflow for `kinhin-xcode`. Expo gets EAS
  config. Opt-in: nothing changes for projects that do not run it. See [docs/mobile-fastlane.md](docs/mobile-fastlane.md).
- `kinhin mobile init` also scaffolds Capacitor and Ionic (`ios/` and `android/`, with `cap sync` in the CI jobs), Kotlin
  Multiplatform (`iosApp/` and `androidApp/`, with the shared framework built by the Xcode build phase), and .NET MAUI
  (`dotnet publish` for the IPA and AAB, signed in the lanes). The runner toolchain probes detect MAUI and KMP.
- The video suite can show store screenshots as a cross-fading slideshow (`device` scene with `props.screens`, opt-in). A new
  `examples/mobile-30s` cut shows them, and `video.yml` captures the iOS screenshots on the macOS pool for a look that sets
  `screens`. Videos without `screens` are unchanged.
- The homepage and README say "Commit it. Screenshot it. Ship it." and cover store screenshots.
- The fastlane lanes accept `IPA_PATH` (a prebuilt IPA, refused when older than `IPA_MAX_AGE_HOURS`), `IOS_PROJECT` and
  `IOS_WORKSPACE`, and `ANDROID_GRADLE_DIR` and `ANDROID_GRADLE_MODULE`. Projects that do not set them are unchanged.
- `kinhin video init | list | build`: make a narrated video of your own product from `.kinhin/videos/*.yml`, with no copy of the
  video suite. It runs a published container image (Apple `container` or Docker) against your repository; `--on-fleet` builds on a
  runner through a generated GitHub workflow. Music, captions, themes and formats are config. See
  [docs/videos-for-your-project.md](docs/videos-for-your-project.md).
- Each video builds into its own folder, `.kinhin/videos/out/<name>/` (the video, WebM, poster, GIF and captions); the build's scratch files are not left in your repository.
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
- Core toolchains (`node`, `go`, `python`, `ruby`, `swift`) install a pinned default version when listed without one,
  instead of a floating `@latest`, so a re-bake reproduces the same versions. Pin a different version in `specs`
  as before. Linux bakes of `swift` also install the Swift runtime libraries it links.

**Fixed**

- An unreadable `fleet.json`, `project-images.json` or scale-set session file is no longer silently replaced. It is moved
  aside to `<name>.corrupt-<timestamp>` before kinhin starts empty, and the app and `kinhin status` show an alert naming
  the kept copy (fleet and project images).
- "Reset everything" no longer reports success when it left something behind. A Tart that cannot be listed, an unreadable
  Keychain or a support directory that cannot be listed is shown before you confirm and again afterwards; `kinhin reset`
  then exits 1 (needs attention), and the app's status line lists what is left.
- Disk checks before a Tart clone use the size of the image being cloned, so a large `images:` image no longer passes as
  if it were the base VM.
- A warm VM is recycled at once when its pool is turned off or its `images:` entry is removed, instead of holding a
  `max_runners` slot for up to an hour.
- A named image that has not been prepared no longer triggers a `tart list` and a warning on every poll. The listing is
  reused for a minute, and the skip is logged once.
- Video text no longer runs off the frame: titles, statements, outro lines, step rows and burned captions wrap on whole words
  and shrink to fit. A slide over its character limit (`TEXT_LIMITS` in `video/shared/resolve.mjs`) fails the build with the
  prop and the limit named.
- Commands that run a child process could return its stderr without the last lines, under load. The result is now read
  only after the pipes reach end-of-file.
- Advanced → Capacity: the This Mac base-image rows no longer run past the card's right edge (the **Pin…** button was clipped), the labels no longer collapse, and the empty gap above **More images** is gone. A custom base image now sits on its own line under the popup.
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
