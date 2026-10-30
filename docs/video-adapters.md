# Recordings of your product

A **device**, **terminal** or **split** scene shows recordings of your product. You do not need recording tools to use a clip you
already have. This page covers the adapter folder that holds the recordings, the claims check that keeps the video honest,
and the optional web recorder.

[← Back to Add videos to your project](videos-for-your-project.md) · [Config reference](video-config.md) · [Troubleshooting](video-troubleshooting.md)

**On this page:** [The adapter folder](#the-adapter-folder) · [Recording clips](#recording-clips) · [Settings an adapter can carry](#settings-an-adapter-can-carry) ·
[Keep it honest](#keep-it-honest) · [Record a web product](#record-a-web-product)

## The adapter folder

An adapter is a folder, `.kinhin/videos/adapters/<name>/`, with an `adapter.yml` that names the clips and a `reference/`
folder that holds them. A video uses it with `adapter: <name>`.

```
.kinhin/videos/adapters/acme/
├── adapter.yml          which clips there are, and settings for every video that uses the adapter
├── claims.json          optional: what your videos must not say (see Keep it honest)
└── reference/
    ├── app.mp4          a screen recording of your app
    └── demo.mp4         a terminal session
```

```yaml
# .kinhin/videos/adapters/acme/adapter.yml
name: acme
description: Acme's own recordings.
captions: { burn: ["9:16", "1:1"] }   # optional (kinhin's own adapter sets burn: false and never burns captions): settings for every video that uses this adapter
clips:
  app:  { kind: app }           # a screen recording of the product      -> reference/app.mp4
  demo: { kind: terminal }      # a terminal session                     -> reference/demo.mp4
  site: { kind: browser }       # a web page being used                  -> reference/site.mp4
```

A video then uses the clips by name:

```yaml
# .kinhin/videos/tour.yml
name: Acme tour
adapter: acme
scenes:
  - { id: app, type: device,   props: { clip: app },  narration: This is the app. }
  - { id: cli, type: terminal, props: { clip: demo }, narration: And this is the command line. }
```

A scene that names a clip the adapter does not declare stops the build and names the scene and the clip.

## Recording clips

Record each clip with anything you like, and save it as `reference/<clip>.mp4`:

- **App:** `kinhin video record <app>` on a Mac (one window, pointer left out; needs Screen Recording permission for your terminal once), or QuickTime. Add `--pointer <clip>-pointer.json` to keep where the pointer was and where it clicked, which a video's [autoZoom](video-config.md#zoom-on-the-clicks-autozoom) follows. Copy that `<clip>-pointer.json` into `reference/` beside the clip, since autoZoom reads it from there.
- **Terminal:** [VHS](https://github.com/charmbracelet/vhs), or any terminal recorder that writes an MP4.
- **Website or browser:** any browser recorder. See [Record a web product](#record-a-web-product) for a scripted option.

H.264 is fine. A few hundred KB to a few MB each is small enough to commit.

- **Where the story starts.** An app clip may have a `<clip>.json` beside it, `{"demoStartsAt": 4.5}`. That is the second into
  the recording where the interesting part begins, so the scene skips what comes before.
- **Named regions (targets).** A clip in `adapter.yml` may name boxes of its picture, as `[x0, y0, x1, y1]` from 0 to 1 across the
  recording: `app: { kind: app, targets: { fleet: [0.17, 0.69, 0.83, 0.94] } }`. A video's [camera, focus and cursor](video-config.md#camera-on-recordings)
  can then say `target: fleet` instead of coordinates, so a redesigned screen is fixed once, here.
- **Terminal variants.** A terminal clip may come in four looks, chosen by the theme's `terminal` mode (`light` or `dark`) and
  the format: `demo.mp4`, `demo-dark.mp4`, `demo-portrait.mp4` and `demo-dark-portrait.mp4`. A missing variant falls back to the
  plain one.

## Settings an adapter can carry

`captions` and `music` in `adapter.yml` apply to every video that uses the adapter (the same blocks as a video's, see
[Captions](video-config.md#captions) and [Music](video-config.md#music)). A video's own settings win.

An adapter can also select a music track for all its videos, and can choose the formats that get burned-in captions. A video can bring them back
with its own `captions` block or `--captions on`.

## Keep it honest

A video is a claim. Say only what your product does today. The build checks the narration, the timed cues and every string in a
scene's props against an adapter's `claims.json` **before anything renders**:

```json
{
  "planned": ["Windows", "Azure Pipelines"],
  "plannedMarkers": ["planned", "roadmap", "coming soon"],
  "forbidden": ["fastest", "enterprise-grade", "revolutionary"]
}
```

- **`planned`** lists names on your roadmap that you have not shipped. A sentence may mention one only if it also says it is
  planned (one of the `plannedMarkers`). "Windows support is planned." passes; "Runs on Windows." fails.
- **`forbidden`** lists words you never want said or shown, such as superlatives you cannot back up.
- A video can add its own rules with a `claims:` block of the same shape.
- A failure names the scene and the text, and stops the build before the voice-over starts.

Put numbers on screen only when you can point at where they come from, and say when they come from one machine.

## Record a web product

This recorder runs from a checkout of the [kinhin repository](https://github.com/RabinApps/kinhin), because it needs host
tools. It is optional: any recording of a web page works. Copy the finished clip into your adapter's `reference/` folder.

```bash
video/scripts/record-web.sh --scenario adapters/kinhin/scenarios/site.json --runner local \
  --serve "npm --prefix website run preview -- --port 4173"
```

`--runner docker` or `--runner apple` runs the same thing in the official Playwright image (Docker, or Apple's `container run`),
so the recording never depends on the host's browser or fonts. The product must be reachable from inside that container: `--serve`
starts it there, or use a public URL. `localhost` on the host is not `localhost` in the container. Set `PACE=0.5` to play a
scenario twice as fast, and `BASE_URL` to point it elsewhere.

A scenario is JSON. Copy `video/adapters/kinhin/scenarios/site.json` to start:

```json
{ "baseUrl": "http://localhost:4173", "viewport": { "width": 1920, "height": 1080 }, "colorScheme": "light",
  "steps": [
    { "do": "goto", "url": "/" },
    { "do": "scroll", "y": 700, "ms": 2200 },
    { "do": "click", "text": "Get started" },
    { "do": "type", "selector": "input[name=q]", "text": "hello", "delayMs": 80 }
  ] }
```

Steps: `goto` (relative to `baseUrl`), `wait` (`ms`), `move`, `hover`, `click`, `type`, `press` (`key`) and `scroll` (`y` pixels,
or `selector`; `ms` is the duration, eased). Target an element with `selector` (CSS or Playwright selectors) or `text`. The page
shows a visible cursor, because Playwright's recording does not draw one. A failing step stops the run with its number and
writes no file.

Other recorders (`record-clip.mjs`, `record-terminal.sh`, `make-reference.sh`) and an `adapters/template/` that records synthetic
clips are in the kinhin repository's `video/` folder, for scripted and repeatable recordings. Their manifest keys are described in
`video/scripts/adapter.mjs`.
