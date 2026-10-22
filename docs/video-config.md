# Video config reference

Everything a video file can say. Start with the [first video](videos-for-your-project.md#your-first-video-in-5-minutes) if you
have not built one yet. Each video is one YAML or JSON file in `.kinhin/videos/`; the fields below go at its top level.

[← Back to Add videos to your project](videos-for-your-project.md) · [Recordings](video-adapters.md) · [Troubleshooting](video-troubleshooting.md)

**On this page:** [The project file](#the-project-file) · [Your own theme](#your-own-theme) · [Scene types](#scene-types) ·
[Camera](#camera-on-recordings) · [Speed ramps](#speed-ramps) · [Split screen](#split-screen) · [Transitions](#transitions) · [Captions](#captions) · [Music](#music) · [Build flags](#build-flags)

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

| Field | What it does |
|---|---|
| `name` | The video's title, shown in `kinhin video list`. |
| `theme` | One of the built-in themes, or one of yours ([below](#your-own-theme)). |
| `format` | `16:9` (default), `9:16` (vertical), `4:5` or `1:1`. |
| `pace` | `0.7` (slower) to `1.6` (faster). Scales the voice and the pauses. |
| `voice` | The narrator. See [Voices](#voices). |
| `overrides` | Changes to the theme for this video only, merged over the theme: `{font: {family: Georgia}, colors: {accent: "#ff7a59"}}`. |
| `adapter` | The product whose recordings the scenes use, by name. Optional for videos made only of drawn scenes. See [Recordings](video-adapters.md). |
| `transition` | How scenes hand over to each other: `fade` (default), `dissolve`, `push`, `slide`, `wipe` or `circle`. A scene can set its own. See [Transitions](#transitions). |
| `captions`, `music` | See [Captions](#captions) and [Music](#music). |
| `scenes` | The scenes, in order. See [Scene types](#scene-types). |

### Voices

`voice: { engine: kokoro, name: af_heart }`. Builds run in the container, which includes **`kokoro`** only (Apache-2.0 model).
Its voices include `af_heart` (default), `af_bella`, `am_michael`, `bf_emma` and `bm_george`. The `supertonic` and macOS `say`
engines need tools on your Mac and are not part of a standard build.

## Your own theme

A theme is the look: the font, the colours, the backdrop, the laptop or window frame, and the caption style. The built-in themes are
`paper` (soft white), `clean` (flat, one blue accent), `midnight` (deep navy), `blueprint` (white lines on blue, monospaced) and
`chalk` (chalk on a green board, handwritten).

Start your own from a built-in one:

```bash
kinhin video theme new acme --from midnight    # writes .kinhin/videos/themes/acme.yml
kinhin video theme list                        # the built-in themes and yours
```

```yaml
# .kinhin/videos/themes/acme.yml
extends: midnight            # a built-in theme, or another of yours
colors:
  accent: "#ff7a59"
  paper: "#0b1020"
font:
  family: Acme Sans          # put the font in .kinhin/videos/fonts/ and it is installed for the build
  fallback: "Helvetica, Arial, sans-serif"
background:
  from: "#0b1020"
  to: "#1c2540"
```

```bash
kinhin video build launch --theme acme    # or theme: acme in the video's file
```

- **`extends`** names the theme to start from. Everything you do not write comes from it. Without `extends` the file must define
  everything: font, all seven colours, backdrop, device look and captions. Copy a built-in theme from the
  [kinhin repository](https://github.com/RabinApps/kinhin/tree/main/video/themes) to do that.
- **Colours** are `#rrggbb`. The build checks the file and names every missing or wrong value, with the file, before anything renders.
- **The seven colours** are `ink`, `muted`, `paper`, `accent`, `card`, `track` and `line`.
- A theme file named like a built-in (`paper.yml`) replaces that theme for your videos. Names use letters, digits, `-` and `_`.
- A video's own `overrides` still apply on top of its theme.

## Scene types

Each scene has an `id`, a `type`, `props`, and its words: `narration` (sentences played in order) or `cues` (each placed `at`
seconds into the scene; a cue's `say` respells what is spoken). `minLength` sets the shortest the scene may be. The voice can
only make it longer.

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
| `code` | A code or terminal block that types itself. `$` and `>` lines are commands, `#` and `//` lines are comments | `label`, `lines`, `caption` |
| `compare` | Two cards, before and after (stacked in portrait and square frames) | `left`, `right` (each `{title, items}`), `caption` |
| `device` | A screen recording in a MacBook frame (drawn, no Apple artwork) that tilts and slides in | `clip`, `frame` (`macbook`, `window` or `none`), `speed` (a number, or [speed ramps](#speed-ramps)) |
| `terminal` | A terminal recording in a window | `clip`, `frame` (`window` or `none`) |
| `split` | Two recordings side by side (one above the other in a vertical or square frame) | `left`, `right` (each a clip with its own [camera](#camera-on-recordings), `speed` and `delay`), `ratio` |

The first ten rows are **drawn scenes**: they need no recording. `device`, `terminal` and `split` show clips from your
[adapter](video-adapters.md). An app clip defaults to the laptop frame; a browser or terminal clip defaults to a window.

A small example that mixes drawn and recorded scenes:

```yaml
scenes:
  - { id: hello, type: title, props: { title: Acme, subtitle: Ship faster }, narration: Acme helps your team ship faster. }
  - { id: steps, type: steps, props: { title: Get started, steps: [Install, Init, Build] }, narration: Three steps. }
  - { id: app,   type: device, props: { clip: app }, narration: This is the app. }
```

The `device` scene needs an adapter with a clip named `app`. Without one, the build stops and names the missing clip.

## Camera on recordings

A `device` or `terminal` scene can move a camera over its recording, spotlight part of the screen and show a cursor. The picture
inside the laptop or window moves; the frame itself holds still. Every position is a fraction of the recording, from 0 (left or
top) to 1 (right or bottom), so one script works in every format. All three props are optional and combine.

```yaml
- id: fleet
  type: device
  props:
    clip: app
    camera:                                    # zoom and pan
      - { at: 2, zoom: 1.8, to: [0.62, 0.35] }
      - { at: 6, zoom: 1 }
    focus:                                     # dim everything but a box
      - { from: 2, to: 5, box: [0.5, 0.2, 0.8, 0.5] }
    cursor:                                    # a pointer, and a ring where it clicks
      - { at: 2.2, to: [0.7, 0.3] }
      - { at: 3, to: [0.7, 0.3], click: true }
  narration: Here the fleet scales to the queue.
```

| Prop | What it does |
|---|---|
| `camera` | A list of keyframes. At `at` seconds into the scene the camera moves (`move` seconds, 0.8 by default) to `zoom` (1 to 4) centred on `to`, then holds. A keyframe without `zoom` or `to` keeps the one before it. The camera starts at zoom 1, centred. |
| `focus` | A box (or a list of them): `{from, to, box: [x0, y0, x1, y1], dim}`. Between `from` and `to` seconds everything outside the box is dimmed (`dim`, 0.55 by default, up to 0.9), fading in and out. |
| `cursor` | A list of points: `{at, to, click}`. The pointer is at `to` at `at` seconds, travelling from the point before (it sets off up to a second early). `click: true` spreads a ring from the point. Skip it if your recording already shows its own cursor. |

Anywhere a point or a box goes, you can write the name of a **target** instead, a named box of the clip that its adapter
declares (`targets` in [Recordings](video-adapters.md#recording-clips)):

```yaml
camera:  [ { at: 2, target: fleet } ]          # zoom to fit the fleet card, centred on it
focus:   { from: 2, to: 5, box: fleet }        # spotlight it
cursor:  [ { at: 2.2, to: fleet } ]            # the pointer goes to its centre
```

A keyframe's `target` sets `to` and, unless you give a `zoom`, the zoom that fits the box. When the layout of your product changes,
you fix the box once in the adapter and every video follows. `kinhin video validate` names a target that the clip does not have.

### Zoom on the clicks (autoZoom)

`autoZoom: true` (or `{zoom, lead, hold, gap, reach}`) moves the camera for you. It reads the clicks in the clip's pointer log,
`<clip>-pointer.json`, and zooms in on each burst of clicks, then zooms back out. The picture still never shows the pointer.

```yaml
- id: fleet
  type: device
  props:
    clip: app
    autoZoom: true                             # or { zoom: 1.6, lead: 0.6, hold: 1.5, gap: 3, reach: 0.35 }
  narration: Here the fleet scales to the queue.
```

| Setting | What it does (default) |
|---|---|
| `zoom` | How far the camera zooms on a burst of clicks, from 1 to 4 (1.6) |
| `lead` | Seconds before the first click that the zoom starts (0.6) |
| `hold` | Seconds after the last click that the camera stays zoomed (1.5) |
| `gap` | Clicks further apart in time than this make a new burst (3) |
| `reach` | Clicks further apart on the picture than this (a fraction, 0.35) make a new burst |

The log is written by `kinhin video record --pointer PATH` (`record-app.sh` passes it), and `make-reference.sh` carries it into
the committed reference clip. It is only where the pointer was and where it clicked, so a take with no clicks gives no zoom: click
where you want the camera to go while you record. `autoZoom` is camera work of its own, so it does not go with `camera`.

Times are seconds into the scene, after `speed` is applied. The scene's frame, captions and narration are unchanged. Recordings are
drawn at their own resolution, so a zoom of 2 or more is sharpest on a recording made at a high resolution.

## Speed ramps

A recording can play fast through the waiting and slow down for the moment that matters. `speed` is a number (any positive one), or a list of
segments. Each segment plays at its own `speed` up to `until`, a second of the recording counted from where its story starts
(the last segment has no `until` and plays to the end of the scene):

```yaml
- id: boot
  type: device
  props:
    clip: app
    speed: [ { until: 20, speed: 8 }, { until: 30, speed: 1 }, { speed: 4 } ]
    ramp: 0.4                                  # seconds to ease between speeds (default 0.4; 0 jumps)
```

Each speed in the list is from 0.1 to 30. Where the speed changes it eases over `ramp` seconds, through speeds in between, so a jump from 8x to 1x reads as the recording
slowing down. The scene lasts at least as long as its closed segments take to play (in the example, 20/8 + 10 seconds and the two
eases), however short the narration. Camera times count the scene's own seconds, after the ramps. Speed lists work in every frame.

## Split screen

A `split` scene plays two recordings at once, such as a command in a terminal and the app reacting to it. In a 16:9 frame they
sit side by side; in a vertical or square frame the first is above the second.

```yaml
- id: both
  type: split
  props:
    left:  { clip: demo }
    right: { clip: app, delay: 1.5, speed: [ { until: 3, speed: 3 }, { speed: 1 } ], camera: [ { at: 3, target: centre } ] }
    ratio: 0.5
  narration: The command on the left, and what it does on the right.
```

| Prop | What it does |
|---|---|
| `left`, `right` | Each is a clip of your adapter with the props a `device` scene takes: `camera`, `focus`, `cursor`, `speed`, `ramp`. `frame` is `window` (a title bar) or `none`; the default is `none` for a recorded app, which has its own window, and `window` for anything else. |
| `delay` | Seconds a recording waits on its first frame before it plays, to line it up with the other. |
| `ratio` | The left (or top) window's share of the room, 0.3 to 0.7. 0.5 by default. |

Each recording is its own file, so lining up cause and effect is up to you: record them together, or use `delay` and `speed` to
match them. Captions sit at the bottom, as on a terminal scene.

## Transitions

By default each scene fades out through the backdrop colour and the next fades in. A project's `transition` changes every cut;
a scene's own `transition` is how it comes in from the scene before it.

| Transition | What you see |
|---|---|
| `fade` | A dip through the backdrop colour (the default). |
| `dissolve` | A cross-dissolve. |
| `push` | The next scene pushes the last one out to the left. |
| `slide` | The next scene slides up over the last one. |
| `wipe` | A hard-edged wipe from the right. |
| `circle` | The next scene opens from the middle in a circle. |

```yaml
transition: dissolve          # every cut, unless a scene says otherwise
scenes:
  - { id: intro, type: title, props: { title: Acme }, narration: Meet Acme. }
  - { id: app, type: device, transition: push, props: { clip: app }, narration: This is the app. }
```

A transition lasts half a second (less between very short scenes) and is centred on the cut, so no scene moves on the clock and
the narration stays in step. The first scene has nothing to come in from.

## Captions

A video writes two caption outputs. The **caption file** (`out/<name>/<name>.srt`, every cue) is written on every build for a
player. **Burned-in** captions are drawn on the picture. Turn them on or off, and choose their style, in the file:

```json
"captions": { "burn": true, "scenes": "clips", "style": "box", "position": "auto", "size": 1.1, "color": "#ffffff" }
```

| Setting | Values | Default |
|---|---|---|
| `burn` | `true`, `false`, or the formats to burn them in, such as `["9:16", "1:1"]` (clean in the others) | `true` (an adapter can set `false` or a list) |
| `scenes` | `"clips"` (scenes with no text of their own), `"all"`, or a list of scene ids | `"clips"` |
| `style` | `outline` (text with an outline), `box` (a semi-transparent box), `shadow` (a soft drop shadow), `bold` (larger, bold, outlined), `minimal` (small, plain), `karaoke` (bold and outlined, each word lights up as it is spoken) | `outline` (`box` if the theme asks for one) |
| `position` | `auto` (clear of the laptop or window), `bottom`, `top`, `middle` | `auto` |
| `size` | A multiplier, up to 3 | `1` |
| `color`, `outlineColor`, `boxColor`, `font` | `#rrggbb` (`#rrggbbaa` for opacity); a font name | from the theme |
| `highlightColor` | `karaoke` only: the colour of the words already spoken (the rest are `color`, dimmed) | `color` |
| `sidecar` | `true` or `false` | `true` |

```bash
kinhin video build launch --captions off                 # a clean picture; the .srt is still written
kinhin video build launch --captions all                 # burn them into every scene
kinhin video build launch --caption-style box            # outline, box, shadow, bold, minimal or karaoke
```

`karaoke` times each word from its length within the narrated sentence, since the voice reports a sentence at a time, so the light
follows the speech closely but not to the syllable. It suits short sentences and vertical formats best. The caption file is the
same as for every other style.

Later settings win: the theme, then the adapter's `captions` block, then the video's, then the command line. The
[gallery](video-gallery.md#captions) shows every style.

## Music

Nothing plays unless an adapter or the video selects a track. The quickest way to add one is to search for it:

```bash
kinhin video music search "calm piano"          # CC0 and public-domain tracks; the rows are numbered
kinhin video music preview 3                    # listen to row 3 (macOS)
kinhin video music add 3 --video launch         # download it and set music: in .kinhin/videos/launch.yml
kinhin video music list                         # what each video uses, and which saved tracks are unused
```

- **Where results come from.** [Openverse](https://openverse.org), an index of openly licensed audio (mostly Freesound, also
  Wikimedia Commons), plus the tracks built into the video image. No account is needed. Anonymous use allows about 200 searches
  a day.
- **Licences.** Results are CC0 or public domain by default: no credit needed. `--license cc-by` also shows CC BY tracks, which
  need credit. Tracks with a non-commercial, no-derivatives or share-alike condition are never offered.
- **More searches.** Register a free application with Openverse and set `KINHIN_OPENVERSE_CLIENT_ID` and
  `KINHIN_OPENVERSE_CLIENT_SECRET` in your environment for a higher allowance. They are read from the environment only and
  never written to a file.
- **Short loops.** Many results are short loops, which work because the video loops music. Some are sound effects.
  `--min-seconds` (default 20) and `--max-seconds` narrow the results.
- **What `add` does.** It saves the audio to `.kinhin/videos/music/<name>.mp3`, writes `<name>.json` beside it (title, creator,
  source page, licence, SHA-256), and sets `music:` in the video's YAML, leaving the rest of the file and its comments alone.
  With one video in the folder it is chosen for you; with several, name it with `--video`. `--volume` sets the level
  (default 0.35), and `--no-config` only downloads and prints the block. A JSON config is not rewritten: the block is printed
  for you to paste.
- **Credit.** For a CC BY track, `add` writes the credit into `credit:`, and the build saves it to `out/<name>/music-credit.txt`.
  Put it in your video description.
- **Your responsibility.** Licences are as each source declares them. Check the track's page (`preview` prints it) before you
  publish, and keep the `.json` record with the audio.

### The setting

```yaml
music:
  track: .kinhin/videos/music/calm-piano.mp3   # a file in your repository, a catalog name, or an https URL (with sha256)
  volume: 0.35         # before ducking under the voice
  duck: true           # lower it while the narrator speaks
  fadeIn: 2
  fadeOut: 3
  start: 0             # seconds into the track
  loop: true
  credit: "..."        # written to out/<name>/music-credit.txt
```

`track` is one of three things:

- a **file** in your repository (mp3, m4a, wav, flac or ogg);
- a **catalog name** (`first-light-particles` ships in the image, CC0, so a build needs no network);
- an **https URL** with `sha256`. The download is refused if it does not match.

`music: path/to/track.mp3` is short for `{track: ...}`, and `music: false` turns off a track an adapter selects. Later settings
win: adapter, then video, then the command line or environment (`--music <track|file|URL|off>`, `VIDEO_MUSIC`,
`VIDEO_MUSIC_SHA256`, `VIDEO_MUSIC_VOLUME`, `NO_MUSIC=1`).

A track you supply is your responsibility to have the right to use.

## Build flags

```bash
kinhin video build launch                                   # your .kinhin/videos/launch.yml
kinhin video build launch --fast                            # a preview: quicker encode, no WebM
kinhin video build launch --quality high --fps 60            # slower, larger encode at 60 fps
kinhin video build launch --theme midnight --format 9:16    # another look or frame, without editing the file
kinhin video build launch --runtime docker                  # pick the runtime
```

The render cache is `.kinhin/videos/.cache`. A scene is re-rendered only when something that shapes it changed: its type and
props, its length, the theme, the format, or the scene sources. A second build after editing one line re-renders one scene.
Delete the cache to render everything again. How a build works step by step is in
[making a video](making-a-video.md#how-the-build-works).
