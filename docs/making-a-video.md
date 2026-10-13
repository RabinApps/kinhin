# Making kinhin's demo video

How kinhin makes its own launch video and demos: a debug build replays a scripted fleet (jobs arrive, instances clone,
boot, run and are deleted, one fails and its retry passes) while you screen-record the real app. This page is for people
working on kinhin. To make videos of **your own product**, see [Add videos to your project](videos-for-your-project.md): the
project file, scene types, adapters, captions, music and the `.kinhin/videos/` folder are documented there.

[← Back to README](../README.md) · [Contributing](../CONTRIBUTING.md) · [The app](app.md) · [Add videos to your project](videos-for-your-project.md)

## The pieces

A video is a list of scenes (see [The project file](videos-for-your-project.md#the-project-file)). Each scene is either a
**canvas scene** drawn by Motion Canvas (title, statement, queue, parallel, map, outro) or a **clip scene** around a
recording of your product: its app, a terminal, or a browser session. Everything that is specific to one product lives in an
[adapter](videos-for-your-project.md#adapters-your-own-product) (`video/adapters/<name>/`); the pipeline never mentions a product. Browser clips need
no Mac, no desktop session and no permission grant, so they are the easy path for anything that runs in a browser (a
`device` scene with `"frame": "window"` and a clip recorded by `record-web.sh`).

| Piece | What it is | Where |
|---|---|---|
| Adapter | One product's recorders, tape and committed clips; kinhin's is `video/adapters/kinhin/`, a starting point is `adapters/template/` | `video/adapters/<name>/` |
| Demo fleet (kinhin) | A debug-only `FleetServing` that replays a script; touches no config, Keychain, daemon or forge | `Sources/kinhin-app/Demo/` |
| App clip | A screen recording of the product's window, from the adapter's `record-app.sh` (kinhin's: `screencapture` on a Mac or in a throwaway Tart VM) | `video/adapters/kinhin/record-app.sh`, `record-app-in-tart.sh` |
| Browser clip | Scripted Playwright session, in a container or locally; an adapter clip of kind `browser` | `video/sources/web/`, `video/adapters/<name>/scenarios/`, `video/scripts/record-web.sh` |
| Terminal clip | A [VHS](https://github.com/charmbracelet/vhs) tape, recorded in four variants by `scripts/record-terminal.sh` (kinhin's runs the real CLI from a debug build in a throwaway support dir and hides the empty-config lines) | `video/adapters/kinhin/terminal/*.tape` |
| Canvas scenes | [Motion Canvas](https://motioncanvas.io) (MIT), themed and sized by the project file | `video/src/` |
| Build | Voice, retime, render, frame, mix, captions | `video/scripts/build.sh` |

Motion Canvas rather than Remotion because Remotion's license requires a paid company license above three employees.
Run `video/scripts/doctor.sh` to see which tools this machine is missing.

## Run the demo app (the kinhin adapter)

```bash
KINHIN_SUPPORT_DIR=$(mktemp -d) KINHIN_DEMO=launch scripts/dev-run.sh --env-tokens
```

`KINHIN_DEMO` takes a built-in script name (`launch`) or the path to a JSON script. It only works in debug builds, so
a release build can never be switched into demo mode. The temp support directory and `--env-tokens` keep the run away
from your real config and Keychain.

## Write a demo script

A script is a looping timeline. Copy `video/adapters/kinhin/demos/example.json` and edit it:

```json
{
  "period": 30,
  "capacity": 2,
  "jobs": [
    { "repo": "acme/api", "account": "github", "runtime": "docker", "workflow": "CI",
      "arrive": 1, "start": 2, "run": 8, "fails": false }
  ]
}
```

- `period`: seconds before the script loops. `capacity`: concurrent instance slots shown.
- `arrive`: when the job enters the queue. `start`: when a slot claims it (keep `start` at or after `arrive`; a gap
  is time spent queued). `run`: seconds the job is busy. `fails` (optional): the instance goes `failed`, raises an
  alert, then is deleted.
- `account` is a forge id (`github`, `gitlab`, `gitea`, `forgejo`). `runtime` is `tart`, `appleContainer`, `docker`
  or `host`; it sets how long clone, boot and registration take.
- The app rejects a script that cannot play (job ends after the loop, `start` before `arrive`, unknown forge) and
  logs why. Keep concurrent instances at or below `capacity`.

Built-in scripts live in `DemoTimeline.builtIn`; add one there when a script should ship with the debug app.

## Record

On a Mac with a desktop: `video/adapters/kinhin/record-app.sh` (needs Screen Recording permission for your terminal once, and
Accessibility if you want it to resize the window). Run it directly in a terminal: piping its output (`| tail`) removes the
TTY that `scripts/dev-run.sh` insists on. The debug app's process and window are named `kinhin-app`.

No spare desktop, or you want a clean repeatable one? `video/adapters/kinhin/record-app-in-tart.sh` records inside a throwaway
Tart VM:

- `--gui`: a VM window on your Mac; the guest has a real desktop session.
- `--vnc`: the same desktop with no window; connect with Screen Sharing.
- `--headless`: no desktop, so no recording. It runs the demo unit tests and renders the offscreen UI captures
  (`shots/capture`) instead.

Both set `KINHIN_DEMO` the same way (`KINHIN_DEMO=path/in/repo.json video/adapters/kinhin/record-app.sh`). For auto-zoom and a
smoothed cursor, run the raw take through an open-source editor such as OpenScreen or Screenize.

## Build the launch video

```bash
video/scripts/build.sh --container                  # video/script/launch.json, in a container
video/scripts/build.sh --container --fast           # a preview
video/scripts/build.sh --project examples/kinhin-30s --container   # the 30-second cut
```

`launch` and `examples/kinhin-30s` use the `kinhin` adapter (`video/adapters/kinhin/adapter.json`), which sets two things
for every kinhin video: burned-in captions are **off** (a clean picture; the `.srt` is still written) and the music is
**First Light Particles**. A project can override either (`"captions": {"burn": true}`, `"music": false`). How the build
works, and every setting, is in [Add videos to your project](videos-for-your-project.md#build-and-iterate).

`build.sh` is the developer path: it builds from this working tree, in a container (`--container`) or on this machine. What
users run is `kinhin video build`, which pulls a published image that has this `video/` folder inside it (`Dockerfile`'s
last layer) and runs `scripts/container-build.sh` against their repository. To try that flow against your working tree:

```bash
docker build -t kinhin-video:local video/        # or: container build -t kinhin-video:local "$PWD/video"
cd /path/to/some/repo && kinhin video build launch --image kinhin-video:local
```

Both runtimes build it. With Apple's `container` use an absolute build path that is not under a symlink (not `/tmp` or `/var/folders`,
which are symlinks on macOS): before `container` 1.5.0 (checked: 1.5.0 builds it correctly from a `/var/folders` path), `container build` silently copies no files from a directory when the context
path has a symlinked parent ([apple/container#2285](https://github.com/apple/container/issues/2285)), so `COPY . /work` yields an empty
suite. `scripts/build.sh --container` resolves the path for you. The image is published to `ghcr.io/rabinapps/kinhin-video` by `.github/workflows/video-image.yml` when a `v*` tag is pushed.

The kinhin launch video's music is [First Light Particles](https://opengameart.org/node/182244) by Yoiyami (CC0: no credit
needed, anyone may reuse it), baked into the image from `video/music/catalog.json`. Use only CC0 tracks in kinhin's own
videos, and do not commit tracks under licences that forbid redistributing the file on its own (Pixabay's does).

## Recording the app

kinhin's `record-app.sh` starts the demo at a known moment (`KINHIN_DEMO_ORIGIN`) and writes `app.json`; the `device` scene
starts the shot there. Keep the mouse pointer off the window while it records. After recording,
`scripts/make-reference.sh --adapter <name>` refreshes the adapter's `reference/` clips (`--terminal` for just the terminal
ones).

## Tests

```bash
video/scripts/test.sh                  # unit tests, seconds: themes, formats, projects, adapters, claims, CI planning, the verifier
video/scripts/test.sh --smoke          # + real builds in a container: hello, the template adapter, a bad claim, a bad theme
video/scripts/test.sh --standard       # + every theme, every format, every scene type, the cache, determinism
video/scripts/test.sh --full           # + the kinhin launch video in every CI look, and all the examples
```

The end-to-end tiers build real videos (in Apple's `container` or Docker; `--host` uses this machine) and judge them with
`video/scripts/verify.mjs`, the same checker CI uses: frame size, length, loudness, black frames, captions, poster and GIF,
and size budgets. [Marketing video in CI](ci-video.md) runs the suite's builds in GitHub Actions, opt-in.

## The site

Copy the built `<project>.mp4`, `<project>.webm` and `<project>-poster.png` from `video/out/` into `website/public/` as
`launch.mp4`, `launch.webm` and `launch-poster.png`. The home page shows the player only when `launch.mp4` exists, so
the site never renders a broken video. Keep the files small (under about 10 MB) or host them elsewhere. The player
can use `<project>.srt` for captions.

## Keep it honest

Only claim what the repo supports. The numbers in [Benchmarks](benchmarks.md) come from one machine and are a sample;
say so. Forges and runtimes that are only planned (see [Forges](forges.md)) do not belong on screen: the kinhin adapter's
`claims.json` makes `scripts/video-claims-lint.mjs` fail a build that mentions them.

## Not yet covered

The demo fleet fills the Fleet tab and menu data. The Logs and Diagnostics windows, and the Advanced tabs, still show
real (empty) data in demo mode; seeding them is the next step if a video needs to open them.
