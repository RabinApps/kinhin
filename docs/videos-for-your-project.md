# Add videos to your project

Make a narrated launch video, a feature clip or a README GIF for **your own product** from a config file that lives in
your repository: scenes, a voice-over, music, captions and a theme, built with one command into an MP4, a WebM, a poster
and a caption file. Everything runs on open-source tools (Motion Canvas, ffmpeg, Kokoro text-to-speech, Playwright), in a
container, from committed files, with no accounts and no network once the image exists.

[← Back to README](../README.md) · [Video gallery](video-gallery.md) · [Marketing video in CI](ci-video.md)

## What you need

- **A container runtime**: Apple's `container` or Docker. Builds run inside the image, so they do not depend on what is
  installed on your machine, and they run the same on Linux.
- **The video suite**: the `video/` folder of the [kinhin repository](https://github.com/RabinApps/kinhin). Copy it into
  your repository (or keep a checkout beside it). It knows nothing about kinhin: everything product-specific lives in your
  `.kinhin/videos/` folder.
- Optional, only to record your own clips: a terminal recorder ([VHS](https://github.com/charmbracelet/vhs)) for terminal
  clips, and a Mac for app clips. Browser clips need nothing but the container. `video/scripts/doctor.sh` lists what is missing.

A video of only title, statement, stats, steps, code and other drawn scenes needs no recording at all.

## Quick start

Keep the video configs in your repository, in
a `.kinhin/videos/` folder, one file per video (YAML or JSON, subfolders allowed), and point the build at it:

```
your-repo/
└── .kinhin/videos/
    ├── launch.yml              one video
    ├── social/vertical.yml     another (name: social/vertical)
    └── adapters/acme/adapter.yml   your product's clips, if you have any
```

```yaml
# .kinhin/videos/launch.yml: the same fields as a project file (see "The project file" below)
name: Acme launch
theme: midnight
voice: { engine: kokoro, name: af_heart }
music: { track: audio/bed.mp3, volume: 0.25 }   # a file in your repository, or a catalog track
captions: { burn: true, style: box }
scenes:
  - id: intro
    type: title
    props: { title: Acme, subtitle: Ship faster }
    narration: Acme helps your team ship faster.
```

```bash
video/scripts/build.sh --container --source ~/code/acme --project launch
```

`--source` mounts your repository read-only into the container; `launch` is `.kinhin/videos/launch.yml` there (your files win over a built-in project of the same name). Paths in the config, such as a music file, are relative to your repository.
Several files give you several kinds of video: a launch film, a vertical cut, a 30-second teaser, each with its own
theme, format, music and captions. `.kinhin/videos/` sits beside `.kinhin/config.yml` (kinhin's toolchains file, which rejects keys it does not know);
kinhin's toolchains loader never reads the videos folder.

## The project file

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

## Scene types

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

## Adapters: your own product

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

## Captions

Captions have two parts: the **caption file** (`out/<project>.srt`, every cue, written on every build for a player) and
**burned-in** captions drawn on the picture. Turn the burned-in ones on or off, and choose their style, in the project file
or from the command line:

```json
"captions": { "burn": true, "scenes": "clips", "style": "box", "position": "auto", "size": 1.1, "color": "#ffffff" }
```

| Setting | Values | Default |
|---|---|---|
| `burn` | `true` or `false` | `true` (an adapter can set `false`) |
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
then `--captions`, `--caption-style` (or `VIDEO_CAPTIONS`, `VIDEO_CAPTION_STYLE`). An adapter can turn burned-in
captions off for every video of its product (kinhin's does); add `"captions": {"burn": true}` to a project (or pass
`--captions on`) to bring them back. The [gallery](video-gallery.md#captions) shows every style.

## Music

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

An adapter can select a track for every video of its product (kinhin's selects First Light Particles); a project picks its
own, or `"music": false` for none. To add a catalog track, add an entry to `music/catalog.json` (`url`, `sha256`, `license`,
`ext`; `"bundled": true` bakes it into the image). A track you supply is your responsibility to have the right to use.

## Build and iterate

```bash
video/scripts/build.sh --container --source . --project launch          # your .kinhin/videos/launch.yml
video/scripts/build.sh --container --source . --project launch --fast   # a preview: quicker encode, no WebM
video/scripts/build.sh --container --source . --project launch --theme midnight --format 9:16   # another look or frame
video/scripts/build.sh --container --runtime docker --source . --project launch                 # pick the runtime
```

The container image (`video/Containerfile`: Playwright's Chromium, ffmpeg with libass, Kokoro and its model, the theme
fonts, the bundled music) is the canonical build, so the result does not depend on what is installed. Without
`--container` the same steps run on this machine (see `video/scripts/doctor.sh`). Your clips come from
`video/raw/<adapter>/` when you have recorded them, else from the adapter's committed `reference/` clips. The result is in
`video/out/`: `<project>.mp4`, `.webm`, `-poster.png`, `-hero.gif` and `.srt`.

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

### Faster iteration

A scene is re-rendered only when something that shapes it changed (its type and props, its length, the theme, the
format, or the scene sources), so a second build after editing one line re-renders one scene (`RENDER_FORCE=1` renders
everything). `build.sh --fast` skips the WebM and encodes quicker, which is what pull-request previews use.

## Examples

`video/script/examples/` has a dozen finished projects, each with a different theme, format, voice and mix of scenes:
`hello` (the smallest), `scene-tour` (all ten canvas scene types), `product-launch`, `release-notes`, `social-teaser`
(9:16), `tutorial-chalk`, `architecture-blueprint`, `oss-announcement` (4:5), `changelog-month` (1:1),
`code-walkthrough` and `kinhin-30s` (kinhin's own adapter, a worked example of one). `video/script/template-demo.json` uses all three clip
kinds. The [gallery](video-gallery.md) shows each one and how to build it; `video/scripts/gallery.mjs` rebuilds the lot.

## In CI

The same builds can run in GitHub Actions on a release or a pull request, opt-in and with no secrets: see
[Marketing video in CI](ci-video.md).

## Keep it honest

A video is a claim. Say only what your product does today. The suite has a check for that: each adapter can list what is
planned or unsupported and words you never want said (`adapters/<name>/claims.json`, or a `claims` block in the project),
and `video/scripts/video-claims-lint.mjs` fails the build when a scene says them. Put numbers on screen only when you can
point at where they come from, and say when they come from one machine.

Use music you have the right to use. The catalog ships one CC0 track; a track you add is your responsibility.
