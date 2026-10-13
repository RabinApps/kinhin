# Plan: the marketing suite in CI/CD (opt-in)

> **Status: phases 1 to 4 built; phase 5 and part of phase 6 deferred.** The guide for what exists is
> [Marketing video in CI](../ci-video.md). This document keeps the reasoning and the remaining work.
>
> | Built | Where |
> |---|---|
> | Opt-in workflow: manual dispatch, release, pull-request preview, schedule | `.github/workflows/video.yml` |
> | Switches: the `VIDEO_CI` variable, `video/ci.json`, the `marketing` environment | `video/ci.json`, `video/scripts/video-ci.mjs` |
> | Planner (pure, unit-tested), budgets, job summary | `video/scripts/video-ci.mjs` |
> | Honesty gate: planned platforms and tone words | `video/scripts/video-claims-lint.mjs`, `adapters/*/claims.json` |
> | Output contract: size, length, loudness, black frames, captions, poster, GIF | `video/scripts/verify.mjs` (shared with the e2e tests) |
> | Publish: attach to the release, open a site pull request (both reviewed, both off by default) | `publish-release`, `publish-site` jobs |
> | Incremental scene cache, `--fast` preview look | `render-titles.mjs`, `assemble.mjs`, `build.sh --fast` |
> | Tests: 40+ unit tests, e2e tiers (smoke, standard, full), wired into `scripts/check.sh` and the CI docs job | `video/tests/`, `video/scripts/test.sh`, `scripts/video-check.sh` |
>
> | Deferred | Why |
> |---|---|
> | Phase 0 spike on the `kinhin-container` pool, and a prebuilt image in a registry | Decided on hosted Linux with `docker build` per run (a cold build is a few minutes); a registry image needs repository settings only a maintainer can change |
> | Phase 5: a `record` job on the Mac runner that re-records the clips and opens a pull request | Needs the maintainer's runner and Screen Recording grant; the committed reference clips make it optional |
> | A release-notes video generated from the changelog | `examples/release-notes` is the template; generating it automatically needs a decision on copy (see "Decisions needed") |
> | A reusable `workflow_call` | Another product copies `video/` and `video.yml` instead; the workflow reads only `ci.json` |

## Production readiness (audited 2026-10-12)

What was verified, how, and what is still needed before this runs unattended in the repository's pipelines.

| Question | Status | Evidence |
|---|---|---|
| Does the image carry everything a build needs? | Yes | Chromium, ffmpeg with libass, fonts, the Kokoro model and voices, and the CC0 music are in the image. A video builds with the network off (`CONTAINER_NETWORK=none`, e2e test `needs no network`). |
| Does it work for people without a Mac? | Yes | Builds from committed files only (reference clips in `adapters/*/reference/`); verified in Apple `container` and Docker. |
| Does it work on x64 (GitHub's hosted runners)? | Built and verified under emulation | The x64 image builds and `examples/hello` verifies (-16.4 LUFS); a real hosted runner has not run it. |
| Does the workflow file work? | Partly verified | `actionlint` clean; the `plan` job runs under `act` with correct outputs; the planner and workflow policies are unit-tested. The claims, build and publish jobs have not run on GitHub: they need the branch pushed. |
| Is it in the VM images (Tart runners) or a registry? | Registry: not yet run | The image is self-contained (the suite is baked in) and `video-image.yml` publishes it to ghcr.io on release tags, but that workflow has not run. The runner VM images do not include it; fleet builds pull it. |
| Tests | Green | 50 unit tests; the smoke, standard and full e2e tiers pass; `scripts/check.sh --serial` passes. |

Found and fixed during the audit: the Docker CPU flag would have failed on a hosted runner with fewer than four cores; the
image warm-up was hiding a missing voice; builds needed the network for the music; an arm64 image could have satisfied an x64
build; and a fresh clone showed that a `--fast` build (what pull-request previews use) exited 2, because the final file listing
globbed a WebM that `--fast` does not write (stale files in a working tree had hidden it).

**Still needed for production**

1. Push the branch and run the workflow by hand on GitHub (`workflow_dispatch`, `VIDEO_CI=true`) to prove the claims, build and
   artifact jobs on a real x64 runner. Check the time and the disk use.
2. Publish the image to `ghcr.io`. `.github/workflows/video-image.yml` does it on every `v*` tag (`ghcr.io/rabinapps/kinhin-video:<version>`,
   `:latest` for stable tags, linux/amd64 and linux/arm64) and the suite is baked into the image, which is what `kinhin video build` pulls. It
   has not run yet: it needs a tag pushed, and a maintainer must make the package public once. `video.yml` can then pull it instead of
   building it in each matrix job.
3. Create the `marketing` environment with required reviewers and set the `VIDEO_CI` variable; leave `ci.json` off until the
   first dispatch run looks right.
4. ~~Pin the base image by digest and keep the pins fresh~~ Done: `video/Dockerfile` pins the Playwright image by its multi-arch
   digest, `.github/dependabot.yml` watches the Dockerfile and `video/package.json` weekly (alongside Swift and the workflows'
   actions), and a unit test fails a pull request that bumps the image's Playwright version without `playwright-core` (or the
   reverse). The apt packages are not pinned.
5. ~~Delete `.github/workflows/demo-check.yml` (temporary)~~ Done; merge the branch through a pull request.
6. Decide the open questions below (release-notes copy, registry, who reviews).



**Goal.** A maintainer can switch on automated marketing assets (a launch video per release, social cuts, a release-notes
video, a PR preview of video changes) with one setting, review what it produced, and publish it, without anyone running
the build by hand. A project that never opts in sees no new jobs, no new cost and no new permissions.

**Non-goals.**

- Posting to social networks. The pipeline produces files and drafts; a human publishes.
- Blocking anything. A failed or skipped video job never fails a release, a docs deploy or a PR gate.
- Generating claims. Text comes from committed project files and the changelog, not from a model at build time.
- Needing secrets. The build uses none; publishing uses the workflow's own `GITHUB_TOKEN`.

## What exists today

| Piece | State |
|---|---|
| Build | `video/scripts/build.sh [--container] [--theme T] [--format F] [--project P] [--adapter A]`; verified in Apple `container` and Docker |
| Image | `video/Dockerfile`: Playwright Chromium, ffmpeg with libass, fonts, Kokoro with its model baked in |
| Inputs | `video/script/<name>.json` (theme, format, typed scenes, narration), `video/themes/`, `video/adapters/<name>/` (recorders, tape, small `reference/` clips) |
| Outputs | `video/out/<name>/<name>.mp4` (name = `<project>[-theme][-format]`), `.webm`, `-poster.png`, `-hero.gif`, `.srt` |
| Pipelines | `ci.yml` (self-hosted `kinhin-xcode` Tart VM, plus a hosted macOS job), `docs.yml` (`kinhin-container` pool, deploys Pages), `release.yml` (tag, `kinhin-xcode`, protected `release` environment), `e2e.yml` (self-hosted `kinhin-e2e`), `demo-check.yml` (temporary, branch-only) |
| Site | `website/.vitepress/theme/LaunchVideo.vue` shows a player only when `launch.mp4` exists in `website/public/` |
| Honesty rules | `docs/making-a-video.md` "Keep it honest": only claim what the repo supports; planned forges and runtimes stay off screen |

## Principles

1. **Opt-in at every level.** Repository (a setting), event (which triggers run), run (a label or a dispatch input).
   Each level defaults to off.
2. **Separate workflow, separate blast radius.** `video.yml` is its own file. `ci.yml`, `docs.yml` and `release.yml` do not
   need it to pass, and it can be deleted without touching them.
3. **Fork-safe.** Never runs on pull requests from forks. Self-hosted macOS runners are used only for tags and manual
   dispatch, never for PRs.
4. **Reproducible.** The same container image, pinned action SHAs (as the other workflows do), pinned npm lockfile, the
   music file verified by SHA-256, the voice model baked into the image.
5. **Review before publish.** Assets land as workflow artifacts and as a draft on the release. Anything that reaches the
   site goes through a pull request, never a direct push.
6. **Honest by construction.** A claims check runs before the build and fails the job on anything the repo does not
   support.

## The opt-in switches

| Level | Switch | Default | Effect |
|---|---|---|---|
| Repository | Actions variable `VIDEO_CI` = `true` | unset | Every job in `video.yml` is skipped unless set. The kill switch. |
| Repository | `video/ci.json` `"enabled": true` | `false` | The file declares what to build; with it off the plan job emits an empty matrix. |
| Event | `ci.json` `triggers.release` | `false` | Build after a release is published. |
| Event | `ci.json` `triggers.pullRequest` | `false` | Build a preview when a PR has the `video-preview` label (or touches `previewPaths`). |
| Event | `ci.json` `triggers.schedule` | `null` | A cron for a monthly refresh. Off. |
| Run | `workflow_dispatch` inputs | n/a | Pick project, theme, format and adapter by hand: the "campaign" button. |
| Publish | `ci.json` `publish.site`, `publish.release` | `false` | Whether finished assets may be offered to the release or to the site (still gated by an environment). |

## Architecture

### The configuration: `video/ci.json`

```json
{
  "enabled": false,
  "triggers": { "release": false, "pullRequest": false, "schedule": null },
  "previewPaths": ["video/**", "docs/making-a-video.md"],
  "projects": [
    { "project": "launch", "looks": [ {}, { "theme": "midnight", "format": "9:16" }, { "format": "4:5" } ] }
  ],
  "publish": { "release": false, "site": false },
  "budgets": { "mp4MB": 10, "seconds": 90, "buildMinutes": 20 },
  "vars": { "version": "from the tag", "facts": "from CHANGELOG.md" }
}
```

A small script, `video/scripts/video-ci.mjs`, reads it and does everything a workflow should not hard-code: validate it,
expand projects and looks into a job matrix, resolve version-dependent text, enforce budgets on the outputs, and write
a job summary. Keeping that in a script means it is testable locally and the workflow YAML stays thin.

### The workflow: `.github/workflows/video.yml`

```
plan ──► claims ──► build (matrix: project × look) ──► checks ──► publish (gated)
                                                    └─► record (optional, macOS)
```

- **`plan`** (hosted `ubuntu-latest`, seconds): applies the switches above, emits the matrix. Skips everything when
  `VIDEO_CI` is not `true`, when the event is a fork PR, or when nothing is enabled.
- **`claims`**: the honesty check (see below). Cheap, runs before any rendering.
- **`build`** (matrix): one container run of `build.sh` per look. Uploads the outputs as an artifact per look.
- **`checks`**: the output contract (see below) on each artifact.
- **`publish`** (protected `marketing` environment, required reviewers): attaches assets to the release as a draft asset,
  and, if enabled, opens a pull request that updates `website/public/launch.*`.
- **`record`** (optional, `kinhin-xcode`): re-records the app and terminal clips on a real Mac and opens a pull request
  with the refreshed `adapters/<name>/reference/` clips. Tags and manual dispatch only.

The workflow is also callable (`on: workflow_call`) with inputs for project, adapter, theme and format, so another
product that adopts the adapter layer can use it from its own repository without copying the YAML.

### Where it runs

| Option | For | Against |
|---|---|---|
| **Hosted `ubuntu-latest`** (recommended for `build`) | Docker is there; no self-hosted exposure; the build needs no Mac; free minutes for a public repository | A cold image build is several minutes (cache it); minutes are metered on a private repository |
| `kinhin-container` pool (kinhin's own Apple-container runners) | Free, fast, and exactly what the docs deploy already uses | Needs a spike: can a job there run a nested container or a `container:` image? If not, only the prebuilt-image route works |
| `kinhin-xcode` (Tart macOS VM) | Needed only for `record` (a real desktop for `screencapture`, VHS, the debug app) | Shared with the fleet and its Keychain: never for PRs, forks or untrusted refs |

**Decision to confirm in the spike:** build on hosted Linux with a prebuilt image from the container registry
(`ghcr.io/<owner>/kinhin-video:<hash>`, tagged by a hash of `Dockerfile`, `package-lock.json`, `shared/` and `themes/`)
and keep the Mac runner for `record` only.

### The honesty gate: `video/scripts/video-claims-lint.mjs`

Runs on the project JSON, the changelog-derived text and the adapters' narration, before any rendering. It fails on:

- a forge, runtime or platform named in a scene that is not supported in `docs/forges.md` and `docs/runtimes.md` (the
  planned ones, such as Buildkite, Azure Pipelines, Bitbucket and Windows, are the deny-list unless the text says "planned");
- a number or benchmark quoted that is not in `docs/benchmarks.md` or the project's `vars`;
- text that contradicts the version being released.

It is useful on its own: `scripts/check.sh` can run it so the main branch cannot carry an unsupported claim in a video
script even when video CI is off.

### The output contract: `checks`

Every look must satisfy, or the job fails (and the failure is reported, never blocking a release):

- dimensions match the format; duration within the budget and within one second of `out/.work/timeline.json`;
- an audio stream is present and its loudness is within 1 LU of -16;
- no black frames in the middle (`blackdetect`); fade edges are allowed;
- caption count equals the cue count; the `.srt` parses;
- the mp4 is under the size budget; the poster is not blank;
- the poster and a contact sheet are attached to the job summary so a reviewer can look without downloading.

## Content flow per trigger

### After a release (`triggers.release`)

1. `release.yml` finishes and the GitHub Release exists (video CI waits for it with `workflow_run` or a polling
   `needs`-style check on the tag; it never runs before the release is published).
2. `video-ci.mjs` resolves version-dependent text: the version badge ("In beta", "v0.2.0") from the tag, and facts from
   the changelog. Template tokens in project JSON (`{{version}}`) are substituted into a temporary copy; the committed
   file is untouched.
3. The default projects build: the launch video in the configured looks (16:9 main, 9:16 and 4:5 social cuts).
4. A **release-notes video** is generated from the changelog section for the tag by a committed project template: one
   `statement` scene per entry (capped), narrated from the entry text with no model involved. A maintainer who wants
   better copy edits a committed `video/script/release-notes.json` in the release PR instead.
5. Assets are attached to the release as a draft asset set and offered for the site through `publish`.

### On a pull request (`triggers.pullRequest`)

Runs only for same-repository PRs that carry the `video-preview` label or touch `previewPaths`. It builds the example
and the changed project at a reduced look (one format) and comments with the artifact link and the contact sheet. It
never publishes.

### By hand (`workflow_dispatch`)

Inputs: project, adapter, theme, format, voice engine, `NO_MUSIC`. This is the "campaign" button: a maintainer picks a
look and gets an artifact bundle. It is also the first thing shipped, because it needs only the workflow and the image.

### On a schedule (`triggers.schedule`)

Off by default. Intended for a monthly rebuild of the main video so that site-facing facts (version, supported lists)
cannot go stale; it opens a pull request only when the output changed.

## Distribution

| Destination | How | Gate |
|---|---|---|
| Workflow artifacts | Always, 14-day retention | none |
| GitHub Release assets | `kinhin-<version>-launch.mp4` and the social cuts, as a draft | `marketing` environment approval |
| Website | A pull request that updates `website/public/launch.mp4`, `launch.webm` and `launch-poster.png` (the player already hides itself when the file is absent) | Pull request review, size budget |
| Social networks | Not automated. The job summary has copy-ready captions and the cut sizes | A human |

## Caching and speed

- **Image:** pull the prebuilt image by hash; rebuild and push only when its inputs changed.
- **Scene cache (later):** key each rendered scene (`raw/scenes/<project>/<id>.mp4`) by a hash of its props, theme, format,
  timing and the scene sources, and skip unchanged scenes. Most releases change one or two scenes.
- **Parallelism:** the matrix runs looks in parallel; scene renders within a look stay sequential (one editor per scene).
- **Budget:** a full build was about four minutes per look on a laptop in a container; the plan assumes 8 to 12 minutes
  per look on a hosted runner including the image pull, and a 20-minute job timeout.

## Security and compliance

- No secrets. `GITHUB_TOKEN` with the narrowest permissions per job (`contents: write` only in `publish`).
- Fork PRs never run it. Self-hosted macOS only for tags and dispatch, behind an environment.
- All actions pinned to commit SHAs, matching the existing workflows; npm from the committed lockfile; the voice model is
  part of the image, not fetched at build; the music file is verified by SHA-256 before use.
- Licenses: Kokoro (Apache-2.0 model) is the CI voice. Supertonic (archived upstream, OpenRAIL-M model) and macOS `say`
  are not used in CI. Music is CC0 only; the track and its source are named in `docs/making-a-video.md`.
- Artifacts are not signed or notarized; they are marketing media, not release binaries, and the release workflow's
  signing steps are untouched.

## Failure handling

A red video job posts a short summary and never blocks: it is not a required check, `release.yml` does not depend on it,
and `docs.yml` does not read its outputs. Flaky renders (headless Chromium) retry once. A budget failure names the
budget and the measured value.

## Phases

Each phase ships on its own and is useful alone.

| Phase | Deliverable | Done when |
|---|---|---|
| **0. Spike** | Decide where `build` runs: nested container on `kinhin-container`, or hosted Linux with a prebuilt image; publish the image to the registry; measure time and cost | A written decision here and one successful build on the chosen runner |
| **1. Manual build** | `video.yml` with `workflow_dispatch` only, off unless `VIDEO_CI=true`; uploads artifacts | A maintainer dispatches it and downloads a video that matches a local build |
| **2. Config and gates** | `video/ci.json`, `video-ci.mjs` (plan, budgets, summary), `claims` and `checks` jobs; `video-claims-lint` also in `scripts/check.sh` | Disabling any switch skips every job; a planted unsupported claim fails the build |
| **3. Release integration** | `triggers.release`; version tokens; changelog-derived release-notes video; draft release assets behind the `marketing` environment | Cutting a beta tag on a fork produces the assets as a draft, with no change to the release itself |
| **4. PR previews** | `triggers.pullRequest` with the label and `previewPaths`; comment with the contact sheet | A PR touching a theme gets a preview; a fork PR gets nothing |
| **5. Fresh recording** | `record` job on `kinhin-xcode`: re-record, `make-reference.sh`, open a PR with the refreshed reference clips | A tag or dispatch opens a PR whose clips match a local recording |
| **6. Site and scale** | Site pull request for `launch.*`; scene cache; the reusable `workflow_call`; docs for other products | A second repository builds its own video with the called workflow |

### Work breakdown (files)

- New: `.github/workflows/video.yml`, `video/ci.json`, `video/scripts/video-ci.mjs`, `video/scripts/video-claims-lint.mjs`,
  `video/script/release-notes.json` (template), `docs/ci-video.md` (the user-facing guide, once built).
- Changed: `video/scripts/build.sh` (a `--out-dir` and a non-interactive mode if the runner needs one),
  `video/scripts/assemble.mjs` (a `--fast` look for previews), `scripts/check.sh` (claims lint, `ci.json` validation),
  `docs/making-a-video.md` (a CI section), `CONTRIBUTING.md` (one paragraph), `CHANGELOG.md`.
- Untouched: `ci.yml`, `docs.yml`, `release.yml`, signing and notarization.

## Test plan

- `actionlint` on `video.yml`; a dry run in a fork with `VIDEO_CI=true` and every trigger exercised once.
- Golden checks on a known project: dimensions, duration, loudness, caption count, size (the `checks` job, also run
  locally with `video-ci.mjs --verify out/`).
- Negative tests: a project naming a planned forge fails `claims`; an over-budget video fails `checks`; a fork PR plans an
  empty matrix; unsetting `VIDEO_CI` skips every job.
- Determinism: two builds of the same inputs produce the same duration and timeline (audio and video bytes may differ).

## Risks

| Risk | Mitigation |
|---|---|
| Build time or minutes grow | Image by hash, scene cache, a `--fast` preview look, a job timeout |
| A render is flaky | One retry; the Chromium launch flags and a fixed viewport are already in `render-titles.mjs` |
| An unsupported claim ships | The `claims` gate, also in `scripts/check.sh`; assets are drafts behind a reviewed environment |
| The self-hosted Mac is exposed | `record` runs for tags and dispatch only, in an environment, never on PRs |
| Upstream model or music changes | Model baked into the image; music pinned by SHA-256; both checked in `checks` |
| The video drifts from the product | The monthly schedule (opt-in) and the release trigger rebuild from current text |
| Other products need different tooling | Adapters carry product specifics; the reusable workflow takes the adapter as an input |

## Decisions needed

1. **Runner for `build`:** hosted Linux with a published image (recommended) or the `kinhin-container` pool. Needs the
   phase 0 spike.
2. **Registry:** publish the image to `ghcr.io` under the repository's owner, or build it in every run.
3. **Where assets go by default:** release draft only (recommended), or also a site pull request.
4. **Release-notes video:** generated from the changelog with no model (recommended), or hand-written per release.
5. **Required reviewers** for the `marketing` environment (the same people as `release`, or a different set).
6. **Scope for other products:** ship the reusable workflow in phase 6, or keep the suite kinhin-only for now.
