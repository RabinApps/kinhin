# Marketing video in CI (opt-in)

The video suite ([Making a demo video](making-a-video.md)) can build a launch video, social cuts and a preview of video
changes in GitHub Actions, from committed sources, with no secrets. It is **off by default**: a repository that does not
opt in gets no jobs, no cost and no new permissions.

[← Back to README](../README.md) · [Making a demo video](making-a-video.md) · [The plan behind it](plans/marketing-suite-in-ci.md)

## Switch it on

Three switches, all off until you flip them:

1. **Repository variable.** Settings → Secrets and variables → Actions → Variables → `VIDEO_CI` = `true`. Without it every
   job in the Video workflow is skipped. This is the kill switch: set it back to `false` to stop everything.
2. **`video/ci.json`.** Set `"enabled": true`, then turn on the triggers you want (`triggers.release`,
   `triggers.pullRequest`, `triggers.schedule`). A manual run does not need `enabled`.
3. **The `marketing` environment** (Settings → Environments). Add required reviewers. Publishing (attaching to a release,
   opening a site pull request) waits for approval there, and only runs when `publish.release` or `publish.site` is `true`.

```json
{
  "enabled": true,
  "triggers": { "release": true, "pullRequest": false, "schedule": false },
  "projects": [
    { "project": "launch", "looks": [{}, { "theme": "midnight", "format": "9:16" }, { "format": "4:5" }] }
  ],
  "publish": { "release": true, "site": false },
  "budgets": { "mp4MB": 10, "seconds": 90, "buildMinutes": 20 }
}
```

## What runs, and when

| Trigger | When | Builds | Publishes |
|---|---|---|---|
| **Manual** (Actions → Video → Run workflow) | You pick project, theme, format, adapter | Exactly that, one look | Nothing: download the artifact |
| **Release** (`triggers.release`) | After the Release workflow succeeds for a tag | Every look in `projects` (the launch video, a vertical cut, a 4:5 cut) | The release (`publish.release`) and a site pull request (`publish.site`), each behind the `marketing` environment |
| **Pull request** (`triggers.pullRequest`) | A same-repository PR with the `video-preview` label, or one that changes a `previewPaths` file | The `preview` set, fast (a quicker encode) | Nothing: artifact and a job summary |
| **Schedule** (`triggers.schedule`) | The first of each month | Every look in `projects` | Nothing |

Pull requests from forks never build. Nothing here needs a secret: the build uses the workflow's read-only token, and only
the two publish jobs get `contents: write` (and `pull-requests: write` for the site pull request).

## The jobs

```
plan ──► claims ──► build (one job per look) ──► publish-release / publish-site (reviewed)
```

- **plan** decides whether to build and what, in seconds.
- **claims** is the honesty gate: it fails when a video says something the product does not support (for kinhin, any of the
  planned platforms such as Buildkite or Windows without saying they are planned, and tone words like "fastest"). The rules
  live in the adapter (`video/adapters/<name>/claims.json`) and the project file.
- **build** runs `video/scripts/build.sh --container --runtime docker` on a hosted Linux runner (the same command you run
  locally), then **verifies** the result and writes a summary table.
- **verify** is the same checker the end-to-end tests use (`video/scripts/verify.mjs`): the frame size, the length against the
  timeline, an audio track near -16 LUFS, no black frames, one caption per cue, a poster and a hero GIF that are not blank, and
  the size and length budgets. A video that fails is not published.

A failed video job never blocks a release, a docs deploy or a pull request: nothing depends on it.

## Try it without GitHub

The decisions are a script you can run here:

```bash
cd video
node scripts/video-ci.mjs validate                        # is ci.json valid?
node scripts/video-claims-lint.mjs --all                  # does every video say only true things?
VIDEO_CI=true GITHUB_EVENT_NAME=workflow_dispatch INPUT_PROJECT=launch \
  node scripts/video-ci.mjs plan                          # what would a manual run build?
scripts/build.sh --container --project examples/hello     # the build itself
node scripts/video-ci.mjs verify out                      # the checks, on a finished build
```

`scripts/video-check.sh` runs the first two plus the unit tests, and `scripts/check.sh` and the CI docs job run it on every
change. See [the tests](making-a-video.md#tests).

## Use it for another product

Copy `video/` and `.github/workflows/video.yml` into the other repository, add an [adapter](making-a-video.md#adapters-your-own-product)
for your product and a project file, set `VIDEO_CI`, and edit `video/ci.json`. The workflow only reads that file; it knows
nothing about kinhin.

## When something fails

| Symptom | Likely cause |
|---|---|
| The workflow shows every job skipped | `VIDEO_CI` is not `true`, or `ci.json` has `"enabled": false`, or the trigger's switch is off. The plan job's log says which. |
| `claims` fails | A scene mentions something the adapter's `claims.json` lists as planned, or a tone word. The message names the scene and the text. |
| `build` fails in `verify` | The log lists each failed check (size, length, loudness, black frames, captions). Budgets are in `ci.json`. |
| A pull request got no preview | It is from a fork, or has neither the `video-preview` label nor a changed `previewPaths` file. |
| `publish-*` waits | It is waiting for approval in the `marketing` environment. |
