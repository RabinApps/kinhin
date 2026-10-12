# Making a demo video

kinhin can be recorded without a forge, a token, a VM or a real queue: a debug build can replay a scripted fleet
(jobs arrive, instances clone, boot, run and are deleted, one fails and its retry passes) while you screen-record the
real app. The `video/` directory turns that recording, a terminal clip and a few title scenes into one narrated video from a
single config file, using only open-source tools. Use it for a release video, a feature clip or a README GIF.

[← Back to README](../README.md) · [Contributing](../CONTRIBUTING.md) · [The app](app.md)

## The pieces

A video is a list of scenes (see [Make a video from a config](#make-a-video-from-a-config)). Each scene is either a
**canvas scene** drawn by Motion Canvas (title, statement, queue, parallel, map, outro) or a **clip scene** around a
recording you made: the app, a terminal, or a browser session. Browser clips need no Mac, no desktop session and no
permission grant, so they are the easy path for anything that runs in a browser (use a `device` scene with
`"frame": "window"` and `"clip": "raw/web.webm"`).

| Piece | What it is | Where |
|---|---|---|
| Demo fleet | A debug-only `FleetServing` that replays a script; touches no config, Keychain, daemon or forge | `Sources/kinhin-app/Demo/` |
| App clip | `screencapture` of the demo app's window, on a Mac or in a throwaway Tart VM | `video/scripts/record.sh`, `record-in-tart.sh` |
| Browser clip | Scripted Playwright session, in a container or locally | `video/sources/web/`, `video/scenarios/`, `video/scripts/record-web.sh` |
| Terminal clip | [VHS](https://github.com/charmbracelet/vhs) tape that runs the real CLI (debug build, throwaway support dir; `trim.sh` masks the empty-config lines) | `video/terminal/*.tape` |
| Canvas scenes | [Motion Canvas](https://motioncanvas.io) (MIT), themed and sized by the project file | `video/src/` |
| Build | Voice, retime, render, frame, mix, captions | `video/scripts/build.sh` |

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

On a Mac with a desktop: `video/scripts/record.sh` (needs Screen Recording permission for your terminal once, and
Accessibility if you want it to resize the window). Run it directly in a terminal: piping its output (`| tail`) removes the
TTY that `scripts/dev-run.sh` insists on. The debug app's process and window are named `kinhin-app`.

No spare desktop, or you want a clean repeatable one? `video/scripts/record-in-tart.sh` records inside a throwaway
Tart VM:

- `--gui`: a VM window on your Mac; the guest has a real desktop session.
- `--vnc`: the same desktop with no window; connect with Screen Sharing.
- `--headless`: no desktop, so no recording. It runs the demo unit tests and renders the offscreen UI captures
  (`shots/capture`) instead.

Both set `KINHIN_DEMO` the same way (`KINHIN_DEMO=path/in/repo.json video/scripts/record.sh`). For auto-zoom and a
smoothed cursor, run the raw take through an open-source editor such as OpenScreen or Screenize.

## Make a video from a config

A video is one JSON file in `video/script/` (the launch video is `launch.json`, a small one is `example.json`): a
theme, a format, and a list of typed scenes with narration. One command builds it, on a Mac or in a container, and
the picture follows the voice, so editing a line re-times everything.

```bash
video/scripts/build.sh                                  # the project's own look (video/script/launch.json)
video/scripts/build.sh --project example                # another project
video/scripts/build.sh --theme midnight --format 9:16   # another look or frame, without editing the file
video/scripts/build.sh --container                      # in a container: Apple's `container` if running, else Docker
video/scripts/build.sh --runtime docker --container
```

The container image (`video/Containerfile`: Playwright's Chromium, ffmpeg with libass, Kokoro and its model, the theme
fonts) is the canonical build, so the result does not depend on what is installed. It needs no Mac: the app and terminal
clips come from `video/reference/` (a few hundred KB, committed) unless you have fresher ones in `video/raw/`.

### The project file

```json
{
  "name": "My product",
  "theme": "midnight",
  "format": "16:9",
  "pace": 1,
  "voice": { "engine": "kokoro", "name": "af_heart" },
  "overrides": { "font": { "family": "Georgia" }, "colors": { "accent": "#ff7a59" } },
  "scenes": [
    { "id": "intro", "type": "title", "props": { "title": "Hello", "subtitle": "my product" },
      "narration": "Meet my product." }
  ]
}
```

- **`theme`**: a file in `video/themes/`: `paper` (soft white, the launch look), `clean` (flat, one blue accent),
  `midnight` (deep navy), `blueprint` (white lines on blue, monospaced), `chalk` (chalk on a green board, handwritten).
  Copy one to `video/themes/<name>.json` and edit it to make your own: the font (`family`, `weight`), `colors` (`ink`,
  `muted`, `paper`, `accent`, `card`, `track`, `line`), the `background` gradient, the `device` look (desktop wallpaper,
  lid, base, window chrome, shadow) and the `caption` style.
- **`overrides`**: change a single value of the theme for this project without copying it (merged over the theme).
- **Fonts.** Any font installed on the machine works by name. Put your own `.ttf` or `.otf` files in `video/fonts/`: the
  container installs them when a build starts. The built-in themes use Inter, DejaVu Sans Mono and Comic Neue, which the
  image has.
- **`format`**: `16:9` (YouTube, web), `9:16` (Shorts, Reels, TikTok), `4:5` (feeds) or `1:1`. The title scenes, the
  device frames and the captions all follow it; the terminal clip's own text stays as recorded.
- **`pace`**: 0.7 (slower) to 1.6 (faster) scales the voice and the pauses.
- **Voices.** `kokoro` (default, Apache-2.0 model), `supertonic` (archived upstream; model under OpenRAIL-M) and macOS
  `say` (Premium voices sound much better). Hear them first with `node video/scripts/voice.mjs --audition`.
  `VOICE_ENGINE` and `VOICE` override the file for one build.

### Scene types

Each scene has an `id`, a `type`, `props`, and its words: `narration` (sentences played in order) or `cues` (each
placed `at` seconds into the scene; a cue's `say` respells what is spoken). `minLength` sets the shortest the scene may
be; the voice can only make it longer.

| Type | Shows | Props |
|---|---|---|
| `title` | A mark that draws itself, a title, a subtitle | `title`, `subtitle`, `mark` (`ring` or `none`) |
| `statement` | One big sentence and a line under it | `text`, `sub`, `size` |
| `queue` | A queue of jobs waiting for one runner | `runner`, `count`, `caption`, `caption2` |
| `parallel` | Items each getting their own fresh card, running side by side, then vanishing | `items`, `card`, `caption`, `done` |
| `map` | Things on the left, things on the right, one hub between them | `left`, `right`, `caption`, `note` |
| `outro` | A closing line, a URL and a row of facts | `line`, `url`, `facts` |
| `device` | A screen recording in a MacBook (drawn, no Apple artwork) that tilts and slides in | `clip`, `frame` (`macbook`, `window` or `none`), `speed` |
| `terminal` | A terminal recording in a window | `clip`, `frame` (`window` or `none`) |

`clip` is `app` or `install` (your `raw/` recording, else the committed one in `video/reference/`) or a path. To add a
scene type, add a file in `video/src/scenes/` (copy `statement.tsx`), a line in `video/src/titles.ts`, and the type in
`video/shared/resolve.mjs`.

### What the build does

1. `scripts/voice.mjs` renders each cue of the narration.
2. `scripts/retime.mjs` makes each scene as long as its speech needs and writes `src/timing.ts`, `out/timeline.json` and
   `captions/<project>.srt`.
3. `scripts/render-titles.mjs` renders every canvas scene headlessly (Playwright's Chromium) to `raw/scenes/<project>/`.
4. `scripts/frames.mjs` puts the device and terminal clips in their frames.
5. `scripts/fetch-music.sh` downloads the CC0 music bed and checks its SHA-256 (`NO_MUSIC=1` skips it).
6. `scripts/assemble.mjs` joins the scenes with short fades, the voice, music ducked under it, and captions into
   `out/<project>.mp4`, `.webm`, `-poster.png`, `-hero.gif` and `.srt` (every caption, for a player). Captions are burned
   into the clip scenes only; the title scenes already show their words.

### Recording the app

`record.sh` starts the demo at a known moment (`KINHIN_DEMO_ORIGIN`) and writes `raw/app.json`; the `device` scene starts
the shot there. Keep the mouse pointer off the window while it records. After `record.sh` and the vhs tape,
`scripts/make-reference.sh` refreshes `video/reference/`.

The launch video's music is [First Light Particles](https://opengameart.org/node/182244) by Yoiyami (CC0: no credit needed,
anyone may reuse it). Use only CC0 tracks, and do not commit tracks under licences that forbid redistributing the file on
its own (Pixabay's does).

## Record a web product

```bash
video/scripts/record-web.sh --scenario scenarios/kinhin-site.json --runner local \
  --serve "npm --prefix website run preview -- --port 4173"
```

`--runner docker` or `--runner apple` runs the same thing in the official Playwright image (Docker, or
apple/container's `container run`), so the recording never depends on the host's browser or fonts. The product must
be reachable from inside the container: `--serve` starts it there, or use a public URL. `localhost` on the host is not
`localhost` in the container. Set `PACE=0.5` to play a scenario twice as fast, `BASE_URL` to retarget it.

A scenario is JSON; copy `video/scenarios/kinhin-site.json`:

```json
{ "baseUrl": "http://localhost:4173", "viewport": { "width": 1920, "height": 1080 }, "colorScheme": "light",
  "steps": [
    { "do": "goto", "url": "/" },
    { "do": "scroll", "y": 700, "ms": 2200 },
    { "do": "click", "text": "Get started" },
    { "do": "type", "selector": "input[name=q]", "text": "hello", "delayMs": 80 }
  ] }
```

Steps: `goto` (relative to `baseUrl`), `wait` (`ms`), `move`, `hover`, `click`, `type`, `press` (`key`) and `scroll` (`y`
pixels, or `selector`; `ms` is the duration, eased). Target an element with `selector` (CSS or Playwright selectors)
or `text`. The page shows a visible cursor, because Playwright's recording does not draw one. A failing step stops the
run with its number and writes no file.

## The site

Copy the built `<project>.mp4`, `<project>.webm` and `<project>-poster.png` from `video/out/` into `website/public/` as
`launch.mp4`, `launch.webm` and `launch-poster.png`. The home page shows the player only when `launch.mp4` exists, so
the site never renders a broken video. Keep the files small (under about 10 MB) or host them elsewhere. The player
can use `<project>.srt` for captions.

## Keep it honest

Only claim what the repo supports. The numbers in [Benchmarks](benchmarks.md) come from one machine and are a sample;
say so. Forges and runtimes that are only planned (see [Forges](forges.md)) do not belong on screen.

## Not yet covered

The demo fleet fills the Fleet tab and menu data. The Logs and Diagnostics windows, and the Advanced tabs, still show
real (empty) data in demo mode; seeding them is the next step if a video needs to open them.
