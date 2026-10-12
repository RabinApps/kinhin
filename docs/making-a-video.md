# Making a demo video

kinhin can be recorded without a forge, a token, a VM or a real queue: a debug build can replay a scripted fleet
(jobs arrive, instances clone, boot, run and are deleted, one fails and its retry passes) while you screen-record the
real app. The `video/` directory turns that recording, a terminal clip and a few title scenes into one narrated video from a
single config file, using only open-source tools. Use it for a release video, a feature clip or a README GIF.

[← Back to README](../README.md) · [Contributing](../CONTRIBUTING.md) · [The app](app.md)

## The pieces

A video is a list of scenes (see [Make a video from a config](#make-a-video-from-a-config)). Each scene is either a
**canvas scene** drawn by Motion Canvas (title, statement, queue, parallel, map, outro) or a **clip scene** around a
recording of your product: its app, a terminal, or a browser session. Everything that is specific to one product lives in an
[adapter](#adapters-your-own-product) (`video/adapters/<name>/`); the pipeline never mentions a product. Browser clips need
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

## Write your own script

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

## Make a video from a config

A video is one JSON file in `video/script/` (the launch video is `launch.json`; a dozen examples are in `video/script/examples/`, shown in the
[gallery](video-gallery.md)): a
theme, a format, and a list of typed scenes with narration. One command builds it, on a Mac or in a container, and
the picture follows the voice, so editing a line re-times everything.

```bash
video/scripts/build.sh                                  # the project's own look (video/script/launch.json)
video/scripts/build.sh --project examples/hello          # another project (a path under video/script/)
video/scripts/build.sh --fast                           # a preview: quicker encode, no WebM
video/scripts/build.sh --theme midnight --format 9:16   # another look or frame, without editing the file
video/scripts/build.sh --container                      # in a container: Apple's `container` if running, else Docker
video/scripts/build.sh --runtime docker --container
```

The container image (`video/Containerfile`: Playwright's Chromium, ffmpeg with libass, Kokoro and its model, the theme
fonts) is the canonical build, so the result does not depend on what is installed. It needs no Mac: the app and terminal
clips come from the adapter's `reference/` directory (a few hundred KB, committed) unless you have fresher ones in
`video/raw/<adapter>/`.

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

- **`adapter`**: the product whose clips the scenes use (`video/adapters/<name>/`); optional for videos made only of
  canvas scenes (`VIDEO_ADAPTER` or `build.sh --adapter` overrides it).
- **`theme`**: a file in `video/themes/`: `paper` (soft white, the launch look), `clean` (flat, one blue accent),
  `midnight` (deep navy), `blueprint` (white lines on blue, monospaced), `chalk` (chalk on a green board, handwritten).
  Copy one to `video/themes/<name>.json` and edit it to make your own: the font (`family`, `weight`), `colors` (`ink`,
  `muted`, `paper`, `accent`, `card`, `track`, `line`), the `background` gradient, the `device` look (desktop wallpaper,
  lid, base, window chrome, shadow, and `terminal`: `light` or `dark`, which terminal clip to use) and the `caption` style.
- **`overrides`**: change a single value of the theme for this project without copying it (merged over the theme).
- **Fonts.** Any font installed on the machine works by name. Put your own `.ttf` or `.otf` files in `video/fonts/`: the
  container installs them when a build starts. The built-in themes use Inter, DejaVu Sans Mono and Comic Neue, which the
  image has.
- **`format`**: `16:9` (YouTube, web), `9:16` (Shorts, Reels, TikTok), `4:5` (feeds) or `1:1`. The title scenes, the
  device frames and the captions all follow it. Portrait and square frames get their own layouts: the queue stacks
  vertically, the map becomes a funnel, the laptop and terminal window sit high and the captions go below them.
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
| `stats` | Big numbers that count up (`75%`, `4`, `1.5x`, `$12` keep their prefix and suffix) | `items` (`{value, label}`), `caption` |
| `steps` | A numbered list that fills in one step at a time | `title`, `steps` |
| `code` | A code or terminal block that types itself; `$` and `>` lines are commands, `#` and `//` lines are comments | `label`, `lines`, `caption` |
| `compare` | Two cards, before and after (stacked in portrait and square frames) | `left`, `right` (each `{title, items}`), `caption` |
| `device` | A screen recording in a MacBook (drawn, no Apple artwork) that tilts and slides in | `clip`, `frame` (`macbook`, `window` or `none`), `speed` |
| `terminal` | A terminal recording in a window | `clip`, `frame` (`window` or `none`) |

`clip` is a clip of the project's adapter (your recording in `video/raw/<adapter>/`, else the committed one in the
adapter's `reference/`) or a path. An app clip defaults to the laptop frame; a browser or terminal clip defaults to a window. A terminal clip comes in four variants, chosen from the theme's `terminal` mode and the
format (`demo`, `demo-dark`, `demo-portrait`, `demo-dark-portrait`); `scripts/record-terminal.sh --all` records them via
VHS, and a missing variant falls back to the plain one. To add a scene type, add a file in `video/src/scenes/` (copy `statement.tsx`), a line in `video/src/titles.ts`, and the type in
`video/shared/resolve.mjs`.

### Adapters: your own product

An adapter is a directory, `video/adapters/<name>/`, holding everything one product needs: an `adapter.json`, the scripts
that record its clips, and small committed `reference/` clips so the video builds without recording anything. The pipeline
only asks an adapter for clips by name. To use yours:

1. Copy `video/adapters/template/` to `video/adapters/<your-product>/` (it builds anywhere: its app clip is a synthetic
   gradient).
2. In `adapter.json` list your clips. There are three kinds:
   - `app`: a `record` script that writes `$VIDEO_RAW_DIR/<clip>.mov` and `<clip>.json`
     (`{"demoStartsAt": seconds into the file at which the story begins}`); use `screencapture` or anything else that
     records your product on screen.
   - `browser`: a scripted browser session of a web product. Give a `scenario` (a JSON of steps, see
     [Record a web product](#record-a-web-product)), a `serve` command that starts the product (run from the repository root),
     a `waitUrl`, and a `runner` (`local`, `docker` or `apple`). No Mac or desktop is needed.
   - `terminal`: a VHS `tape`; `hideFromLine` hides the output from that line down.

   List the tools recording needs under `needs` (`scripts/doctor.sh` checks them).
3. Record any clip with one command, whatever its kind: `node video/scripts/record-clip.mjs --adapter <name> --clip <clip>`
   (a browser clip takes `--runner docker`; extra arguments after `--` go to the recorder). Then make the committed copies:
   `video/scripts/make-reference.sh --adapter <name>`.
4. Point a project at it: `"adapter": "<name>"`, with scenes such as `{"type": "device", "props": {"clip": "app"}}`.
   `video/script/template-demo.json` is a working example: `video/scripts/build.sh --project template-demo`.

### Examples

`video/script/examples/` has a dozen finished projects, each with a different theme, format, voice and mix of scenes:
`hello` (the smallest), `scene-tour` (all ten canvas scene types), `product-launch`, `release-notes`, `social-teaser`
(9:16), `tutorial-chalk`, `architecture-blueprint`, `oss-announcement` (4:5), `changelog-month` (1:1),
`code-walkthrough` and `kinhin-30s` (the kinhin adapter's clips). `video/script/template-demo.json` uses all three clip
kinds. The [gallery](video-gallery.md) shows each one and how to build it; `video/scripts/gallery.mjs` rebuilds the lot.

### What the build does

1. `scripts/voice.mjs` renders each cue of the narration.
2. `scripts/retime.mjs` makes each scene as long as its speech needs and writes `src/timing.ts`, `out/timeline.json` and
   `out/<slug>.captions.srt`.
3. `scripts/render-titles.mjs` renders every canvas scene headlessly (Playwright's Chromium) to `raw/scenes/<project>/`.
4. `scripts/frames.mjs` puts the device and terminal clips in their frames.
5. `scripts/fetch-music.mjs` finds the project's music track (see [Music](#music)), checks its SHA-256 and writes `out/music.json`; no track, no music.
6. `scripts/assemble.mjs` joins the scenes with short fades, the voice, music ducked under it, and captions into
   `out/<project>.mp4`, `.webm`, `-poster.png`, `-hero.gif` and `.srt` (every caption, for a player). Burned-in captions
   follow the project's `captions` block (see [Captions](#captions)).

### Captions

Captions have two parts: the **caption file** (`out/<project>.srt`, every cue, written on every build for a player) and
**burned-in** captions drawn on the picture. Turn the burned-in ones on or off, and choose their style, in the project file
or from the command line:

```json
"captions": { "burn": true, "scenes": "clips", "style": "box", "position": "auto", "size": 1.1, "color": "#ffffff" }
```

| Setting | Values | Default |
|---|---|---|
| `burn` | `true` or `false` | `true` (the kinhin adapter sets `false`) |
| `scenes` | `"clips"` (scenes with no text of their own), `"all"`, or a list of scene ids | `"clips"` |
| `style` | `outline` (text with an outline), `box` (a semi-transparent box), `shadow` (a soft drop shadow), `bold` (larger, bold, outlined), `minimal` (small, plain) | `outline` (`box` if the theme asks for one) |
| `position` | `auto` (clear of the laptop or window), `bottom`, `top`, `middle` | `auto` |
| `size` | A multiplier, up to 3 | `1` |
| `color`, `outlineColor`, `boxColor`, `font` | `#rrggbb` (`#rrggbbaa` for opacity); a font name | from the theme |
| `sidecar` | `true` or `false` | `true` |

```bash
video/scripts/build.sh --captions off                 # a clean picture; the .srt is still written
video/scripts/build.sh --captions all                 # burn them into every scene
video/scripts/build.sh --caption-style box            # outline, box, shadow, bold or minimal
```

Precedence, later wins: the theme's caption look, the adapter's `captions` block (`adapters/<name>/adapter.json`), the project's,
then `--captions`, `--caption-style` (or `VIDEO_CAPTIONS`, `VIDEO_CAPTION_STYLE`). The kinhin adapter turns burned-in
captions off, so the launch video and `examples/kinhin-30s` have a clean picture; add `"captions": {"burn": true}` to a
project (or pass `--captions on`) to bring them back. The [gallery](video-gallery.md#captions) shows every style.

### Music

Music is a setting, like captions. Nothing plays unless an adapter or project selects a track:

```json
"music": { "track": "first-light-particles", "volume": 0.35, "duck": true, "fadeIn": 2, "fadeOut": 3, "start": 0, "loop": true }
```

`track` is a **catalog name** (`music/catalog.json`; ships `first-light-particles`, CC0, baked into the container image so a
build needs no network), a **file** (`"music/my-track.mp3"`, relative to `video/`; mp3, m4a, wav, flac or ogg) or an
**https URL** with `"sha256"` (the download is refused if it does not match). `"music": "music/my-track.mp3"` is short for
`{"track": …}` and `"music": false` turns off what an adapter selects. Precedence, later wins: adapter, project, then the
environment: `--music <track|file|URL|off>`, `VIDEO_MUSIC`, `VIDEO_MUSIC_SHA256`, `VIDEO_MUSIC_VOLUME`, `NO_MUSIC=1`.
`credit` text (or a catalog entry's) is written to `out/music-credit.txt` for your video description.

The kinhin adapter selects First Light Particles, so the launch video and every kinhin project use it; another product's
adapter or project picks its own. To add a catalog track, add an entry to `music/catalog.json` (`url`, `sha256`, `license`,
`ext`; `"bundled": true` bakes it into the image). A track you supply is your responsibility to have the right to use.

### Faster iteration

A scene is re-rendered only when something that shapes it changed (its type and props, its length, the theme, the
format, or the scene sources), so a second build after editing one line re-renders one scene (`RENDER_FORCE=1` renders
everything). `build.sh --fast` skips the WebM and encodes quicker, which is what pull-request previews use.

### Tests

```bash
video/scripts/test.sh                  # unit tests, seconds: themes, formats, projects, adapters, claims, CI planning, the verifier
video/scripts/test.sh --smoke          # + real builds in a container: hello, the template adapter, a bad claim, a bad theme
video/scripts/test.sh --standard       # + every theme, every format, every scene type, the cache, determinism
video/scripts/test.sh --full           # + the kinhin launch video in every CI look, and all the examples
```

The end-to-end tiers build real videos (in Apple's `container` or Docker; `--host` uses this machine) and judge them with
`video/scripts/verify.mjs`, the same checker CI uses: frame size, length, loudness, black frames, captions, poster and GIF,
and size budgets. [Marketing video in CI](ci-video.md) runs the suite's builds in GitHub Actions, opt-in.

### Recording the app

kinhin's `record-app.sh` starts the demo at a known moment (`KINHIN_DEMO_ORIGIN`) and writes `app.json`; the `device` scene
starts the shot there. Keep the mouse pointer off the window while it records. After recording,
`scripts/make-reference.sh --adapter <name>` refreshes the adapter's `reference/` clips (`--terminal` for just the terminal
ones).

The kinhin launch video's music is [First Light Particles](https://opengameart.org/node/182244) by Yoiyami (CC0: no credit needed,
anyone may reuse it). Use only CC0 tracks, and do not commit tracks under licences that forbid redistributing the file on
its own (Pixabay's does).

## Record a web product

```bash
video/scripts/record-web.sh --scenario adapters/kinhin/scenarios/site.json --runner local \
  --serve "npm --prefix website run preview -- --port 4173"
```

`--runner docker` or `--runner apple` runs the same thing in the official Playwright image (Docker, or
apple/container's `container run`), so the recording never depends on the host's browser or fonts. The product must
be reachable from inside the container: `--serve` starts it there, or use a public URL. `localhost` on the host is not
`localhost` in the container. Set `PACE=0.5` to play a scenario twice as fast, `BASE_URL` to retarget it.

A scenario is JSON; copy `video/adapters/kinhin/scenarios/site.json`:

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
