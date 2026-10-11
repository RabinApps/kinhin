# Making a demo video

kinhin can be recorded without a forge, a token, a VM or a real queue: a debug build can replay a scripted fleet
(jobs arrive, instances clone, boot, run and are deleted, one fails and its retry passes) while you screen-record the
real app. The `video/` directory turns that recording, a terminal clip and a few title scenes into one video, using
only open-source tools. Use it for a release video, a feature clip or a README GIF.

[← Back to README](../README.md) · [Contributing](../CONTRIBUTING.md) · [The app](app.md)

## The pieces

| Piece | What it is | Where |
|---|---|---|
| Demo fleet | A debug-only `FleetServing` that replays a script; touches no config, Keychain, daemon or forge | `Sources/kinhin-app/Demo/` |
| App clip | `screencapture` of the demo app's window, on a Mac or in a throwaway Tart VM | `video/scripts/record.sh`, `record-in-tart.sh` |
| Terminal clip | [VHS](https://github.com/charmbracelet/vhs) tape that runs the real CLI | `video/terminal/*.tape` |
| Title scenes | [Motion Canvas](https://motioncanvas.io) (MIT): intro, problem, lanes, outro | `video/src/` |
| Final cut | `ffmpeg` joins the clips into `launch.mp4`, `launch.webm`, `poster.png`, `hero.gif` | `video/scripts/export.sh` |

Motion Canvas rather than Remotion because Remotion's license requires a paid company license above three employees.
Run `video/scripts/doctor.sh` to see which tools this machine is missing.

## Run the demo app

```bash
KINHIN_SUPPORT_DIR=$(mktemp -d) KINHIN_DEMO=launch scripts/dev-run.sh --env-tokens
```

`KINHIN_DEMO` takes a built-in script name (`launch`) or the path to a JSON script. It only works in debug builds, so
a release build can never be switched into demo mode. The temp support directory and `--env-tokens` keep the run away
from your real config and Keychain.

## Write your own script

A script is a looping timeline. Copy `video/demos/example.json` and edit it:

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

On a Mac with a desktop: `video/scripts/record.sh` (needs Screen Recording permission for your terminal once).

No spare desktop, or you want a clean repeatable one? `video/scripts/record-in-tart.sh` records inside a throwaway
Tart VM:

- `--gui`: a VM window on your Mac; the guest has a real desktop session.
- `--vnc`: the same desktop with no window; connect with Screen Sharing.
- `--headless`: no desktop, so no recording. It runs the demo unit tests and renders the offscreen UI captures
  (`shots/capture`) instead.

Both set `KINHIN_DEMO` the same way (`KINHIN_DEMO=path/in/repo.json video/scripts/record.sh`). For auto-zoom and a
smoothed cursor, run the raw take through an open-source editor such as OpenScreen or Screenize.

## Title scenes and the final cut

Edit the words and facts in `video/src/content.ts` (supported forges and runtimes, taglines, the release badge), then:

```bash
cd video && npm install && npm run serve   # opening: intro + problem; npm run serve:closing for lanes + outro
```

Render each from the editor (exporter *Video (FFmpeg)*) to `video/raw/opening.mp4` and `video/raw/closing.mp4`, put
the app and terminal clips in `video/raw/` (`app.mov`, `install.mp4`), and run `video/scripts/export.sh`. Outputs land
in `video/out/`; `raw/` and `out/` are git-ignored.

## Keep it honest

Only claim what the repo supports. The numbers in [Benchmarks](benchmarks.md) come from one machine and are a sample;
say so. Forges and runtimes that are only planned (see [Forges](forges.md)) do not belong on screen.

## Not yet covered

The demo fleet fills the Fleet tab and menu data. The Logs and Diagnostics windows, and the Advanced tabs, still show
real (empty) data in demo mode; seeding them is the next step if a video needs to open them.
