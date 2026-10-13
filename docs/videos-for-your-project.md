# Add videos to your project

Make a narrated launch video, a feature clip or a README GIF for **your own product** from a config file that lives in
your repository: scenes, a voice-over, music, captions and a theme, built with one command into an MP4, a WebM, a poster
and a caption file. Everything runs on open-source tools (Motion Canvas, ffmpeg, Kokoro text-to-speech, Playwright), in a
container, from committed files, with no accounts and no network once the image exists.

[← Back to README](../README.md) · [Video gallery](video-gallery.md) · [Marketing video in CI](ci-video.md)

## What you need

- **kinhin installed** ([Install & updates](install.md)). The video suite is not part of your repository or of kinhin.app: it
  ships in a container image that `kinhin video` pulls the first time you build (about a gigabyte: Node, Chromium, ffmpeg,
  the Kokoro voice model, fonts and the pipeline) and reuses after that.
- **A container runtime**: Apple's `container` (`brew install container && container system start`) or Docker. `kinhin video`
  uses Apple's if it is running, else Docker; `--runtime` picks one. Builds run inside the image, so they do not depend on
  what is installed on your machine.
- Optional, only to record your own clips: a terminal recorder ([VHS](https://github.com/charmbracelet/vhs)) for terminal
  clips, and a Mac for app clips. Browser clips need nothing but the container.

A video of only title, statement, stats, steps, code and other drawn scenes needs no recording at all.

## Quick start

```bash
cd ~/code/acme
kinhin video init launch      # writes .kinhin/videos/launch.yml (and a .gitignore for the output)
kinhin video build launch     # builds it; the first run pulls the image
```

The video lands in `.kinhin/videos/out/` (`launch.mp4`, `.webm`, `-poster.png`, `-hero.gif` and the caption file `launch.srt`). With
one video in the folder you can leave the name out. `kinhin video list` shows what is there.

Each video is one file in `.kinhin/videos/` (YAML or JSON, subfolders allowed), so one repository can hold several kinds:
a launch film, a vertical cut, a 30-second teaser, each with its own theme, format, music and captions.

```
your-repo/
└── .kinhin/videos/
    ├── launch.yml                  one video
    ├── social/vertical.yml         another (name: social/vertical)
    ├── fonts/                      your own .ttf/.otf, installed for the build
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

Paths in the config, such as a music file, are relative to your repository, which is mounted into the container read-only.
Only `.kinhin/videos/out` (the videos) and `.kinhin/videos/.cache` (the render cache) are written.
`.kinhin/videos/` sits beside `.kinhin/config.yml` (kinhin's toolchains file, which rejects keys it does not know); the
toolchains loader never reads the videos folder.

### The commands

| Command | Does |
|---|---|
| `kinhin video init [name]` | Writes a starter `.kinhin/videos/<name>.yml` (default `launch`) and a `.gitignore`. Never overwrites. |
| `kinhin video list` | Lists the videos (`--json` for scripts). |
| `kinhin video build [name]` | Builds one. `--theme`, `--format`, `--captions on\|off\|all`, `--caption-style`, `--music <track\|file\|off>` change the look for one build; `--fast` is a quicker preview. |

Other options: `--dir PATH` (a repository other than the current directory), `--runtime container|docker`, and `--image REF`
(or `KINHIN_VIDEO_IMAGE`) to run a different image, for example one you built yourself from `video/` in the kinhin repository
(`docker build -t kinhin-video:local video/`). The default image is `ghcr.io/rabinapps/kinhin-video:<your kinhin version>`.

### Building on your fleet

`kinhin video build` runs on the Mac you type it on. To build on a runner kinhin serves instead, add a workflow once and use `--on-fleet`:

```bash
kinhin video init --workflow --runs-on self-hosted,linux   # writes .github/workflows/kinhin-video.yml; commit and push it
kinhin video build launch --on-fleet                       # dispatches it, follows the run, downloads the video
```

`--on-fleet` uses the GitHub CLI (`gh`, signed in with `gh auth login`) and works for GitHub repositories. The workflow runs the same image, so the runner needs
Docker and a network that can reach ghcr.io; nothing in the workflow needs a secret. `--ref BRANCH` runs it on another branch.
The video is downloaded to `.kinhin/videos/out/` as with a local build.

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

- **`adapter`**: the product whose clips the scenes use (your `.kinhin/videos/adapters/<name>/`); optional for videos made only
  of canvas scenes.
- **`theme`**: one of the built-in themes, `paper` (soft white), `clean` (flat, one blue accent), `midnight` (deep navy),
  `blueprint` (white lines on blue, monospaced) or `chalk` (chalk on a green board, handwritten), or one of your own
  ([below](#your-own-theme)). A theme sets the font (`family`, `weight`), `colors` (`ink`, `muted`, `paper`, `accent`, `card`,
  `track`, `line`), the `background` gradient, the `device` look (desktop wallpaper, lid, base, window chrome, shadow, and
  `terminal`: `light` or `dark`, which terminal clip to use) and the `caption` style.
- **`overrides`**: change any of those for this one video without a theme file: `overrides: {font: {family: Georgia}, colors: {accent: "#ff7a59"}}`
  (merged over the theme).
- **`pace`**: 0.7 (slower) to 1.6 (faster) scales the voice and the pauses.
- **Voices.** `kokoro` (default, Apache-2.0 model), `supertonic` (archived upstream; model under OpenRAIL-M) and macOS
  `say` (Premium voices sound much better). In the image only `kokoro` is available (the
  others need a host tool); its voices include `af_heart` (default), `af_bella`, `am_michael`, `bf_emma` and `bm_george`.

### Your own theme

Start with `kinhin video theme new acme --from midnight`, which writes `.kinhin/videos/themes/acme.yml` (the values most people
change are there, commented out, with the built-in theme's own values); `kinhin video theme list` shows the built-in themes and
yours. A theme file is `.kinhin/videos/themes/<name>.yml` (or `.json`), and its file name is the `theme:` value. Start from a
built-in theme with `extends` and write only what you change:

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

- **`extends`** picks the theme to start from; everything you do not write comes from it. Without `extends` the file must define
  everything (font, all seven colors, backdrop, device look, captions): copy a built-in theme from the
  [kinhin repository](https://github.com/RabinApps/kinhin/tree/main/video/themes) and edit it.
- **Colors** are `#rrggbb`. The build checks the file and names every missing or wrong value, with the file, before anything renders.
- A theme with a built-in's name (`paper.yml`) replaces that theme for your videos. Names use letters, digits, `-` and `_`.
- A video's own `overrides` still apply on top of the theme.

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

`clip` is a clip of the project's adapter (the committed one in your adapter's `reference/` folder) or a path. An app clip defaults to the laptop frame; a browser or terminal clip defaults to a window. A terminal clip comes in four variants, chosen from the theme's `terminal` mode and the
format (`demo`, `demo-dark`, `demo-portrait`, `demo-dark-portrait`); the kinhin repository's `video/scripts/record-terminal.sh --all` records them via
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
3. Put the recorded clips in your adapter's `reference/` folder (`.kinhin/videos/adapters/<name>/reference/<clip>.mp4`, a few
   hundred KB each, committed) and the build uses them. Recording is the one step that needs tools on the host (a screen
   recorder, VHS, or Playwright); the recorders live in the `video/` folder of the [kinhin repository](https://github.com/RabinApps/kinhin)
   (`scripts/record-clip.mjs`, `record-terminal.sh`, `record-web.sh`, `make-reference.sh`), so use a checkout of it for that step.
4. Point a video at it: `adapter: <name>`, with scenes such as `{type: device, props: {clip: app}}`.
   The kinhin repository's `video/adapters/template/` is a starting point, and `video/script/template-demo.json` a working example.

## Record a web product

These recorders run from a checkout of the [kinhin repository](https://github.com/RabinApps/kinhin); copy the finished clip into your adapter's `reference/` folder.

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
kinhin video build launch --captions off                 # a clean picture; the .srt is still written
kinhin video build launch --captions all                 # burn them into every scene
kinhin video build launch --caption-style box            # outline, box, shadow, bold or minimal
```

Precedence, later wins: the theme's caption look, the adapter's `captions` block (`adapters/<name>/adapter.json`), the project's,
then `--captions`, `--caption-style` (or `VIDEO_CAPTIONS`, `VIDEO_CAPTION_STYLE`). An adapter can turn burned-in
captions off for every video of its product (kinhin's does); add `"captions": {"burn": true}` to a project (or pass
`--captions on`) to bring them back. The [gallery](video-gallery.md#captions) shows every style.

## Music

Music is a setting, like captions. Nothing plays unless an adapter or the video selects a track. The quickest way to get one is
to search for it from the command line.

### Find music and add it

```bash
kinhin video music search "calm piano"          # CC0 and public-domain tracks; the rows are numbered
kinhin video music preview 3                    # listen to row 3 (macOS)
kinhin video music add 3 --video launch         # download it and set music: in .kinhin/videos/launch.yml
kinhin video music list                         # what each video uses, and which saved tracks are unused
```

- **Where results come from.** [Openverse](https://openverse.org), an index of openly licensed audio (mostly Freesound, also
  Wikimedia Commons), plus the tracks built into the video image. No account is needed; without one the library allows about
  200 searches a day (more with your own Openverse application: see below). Results are CC0 or public domain by default: no credit needed, free to reuse. `--license cc-by` also shows
  CC BY tracks, which need credit (see below). Tracks with a non-commercial, no-derivatives or share-alike condition are never offered.
- **More searches.** If you hit the limit, register a free application with Openverse (see its API documentation) and set
  `KINHIN_OPENVERSE_CLIENT_ID` and `KINHIN_OPENVERSE_CLIENT_SECRET` in your environment. kinhin then signs in with them and
  gets a higher allowance and bigger pages. They are read from the environment only and never written to a file.
- **What you get.** Many results are short loops (the video loops music, so that works) and some are sound effects;
  `--min-seconds` (default 20) and `--max-seconds` narrow it, and `preview` lets you hear one first.
- **What `add` does.** It saves the audio to `.kinhin/videos/music/<name>.mp3`, writes `<name>.json` beside it (title, creator,
  source page, license, SHA-256), and sets `music:` in the video's YAML, leaving the rest of the file and its comments alone.
  With one video in the folder it is chosen for you; with several, name it with `--video`. `--volume` sets the level
  (default 0.35), `--no-config` only downloads and prints the block. A JSON config is not rewritten: the block is printed for you
  to paste. A built-in track, such as `first-light-particles`, is named in the config and downloads nothing.
- **Credit.** For a CC BY track `add` writes the credit line into `credit:` and the build saves it to `out/music-credit.txt`;
  put it in your video description.
- **Your responsibility.** Licenses are as declared by each source. Check the track's page (`preview` prints it) before you
  publish, and keep the saved `.json` file with it. Whether to commit the downloaded audio (a few MB) is your call; without it the
  repository still builds only if the file is present.

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
  credit: "..."        # written to out/music-credit.txt
```

`track` is a **file** in your repository (mp3, m4a, wav, flac or ogg), a **catalog name** (`music/catalog.json`; ships
`first-light-particles`, CC0, baked into the container image so a build needs no network) or an **https URL** with `sha256`
(the download is refused if it does not match). `music: path/to/track.mp3` is short for `{track: ...}` and `music: false`
turns off what an adapter selects. Precedence, later wins: adapter, video, then the command line and environment:
`--music <track|file|URL|off>` on `kinhin video build`, `VIDEO_MUSIC`, `VIDEO_MUSIC_SHA256`, `VIDEO_MUSIC_VOLUME`, `NO_MUSIC=1`.

An adapter can select a track for every video of its product (kinhin's selects First Light Particles); a video picks its own, or
`music: false` for none. To add a catalog track, add an entry to `music/catalog.json` in the image's source (`url`, `sha256`,
`license`, `ext`; `"bundled": true` bakes it into the image). A track you supply is your responsibility to have the right to use.

## Build and iterate

```bash
kinhin video build launch                                   # your .kinhin/videos/launch.yml
kinhin video build launch --fast                            # a preview: quicker encode, no WebM
kinhin video build launch --theme midnight --format 9:16    # another look or frame, without editing the file
kinhin video build launch --runtime docker                  # pick the runtime
```

The container image (Playwright's Chromium, ffmpeg with libass, Kokoro and its model, the theme fonts, the bundled music and
the pipeline) is the only build, so the result does not depend on what is installed on your machine. Your clips come from
the adapter's committed `reference/` clips. The result is in `.kinhin/videos/out/`: `<name>.mp4`, `.webm`, `-poster.png`,
`-hero.gif` and `.srt`.

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
everything). `--fast` skips the WebM and encodes quicker.

## Examples

The kinhin repository's `video/script/examples/` has a dozen finished projects (copy one into `.kinhin/videos/` to start from it), each with a different theme, format, voice and mix of scenes:
`hello` (the smallest), `scene-tour` (all ten canvas scene types), `product-launch`, `release-notes`, `social-teaser`
(9:16), `tutorial-chalk`, `architecture-blueprint`, `oss-announcement` (4:5), `changelog-month` (1:1),
`code-walkthrough` and `kinhin-30s` (kinhin's own adapter, a worked example of one). `video/script/template-demo.json` uses all three clip
kinds. The [gallery](video-gallery.md) shows each one.

## In CI

The same builds can run in GitHub Actions on a release or a pull request, opt-in and with no secrets: see
[Marketing video in CI](ci-video.md).

## Keep it honest

A video is a claim. Say only what your product does today. The suite has a check for that: each adapter can list what is
planned or unsupported and words you never want said (`adapters/<name>/claims.json`, or a `claims` block in the project),
and the build fails when a scene says them. Put numbers on screen only when you can
point at where they come from, and say when they come from one machine.

Use music you have the right to use. The catalog ships one CC0 track; a track you add is your responsibility.

## Troubleshooting

| You see | Cause and fix |
|---|---|
| `videos build in a container, and neither Apple's container nor Docker is running` | Start one: `container system start` (install with `brew install container`), or open Docker Desktop. `--runtime container` or `--runtime docker` forces one and says why it is not usable. |
| `no .kinhin/videos/ in <path>` or `no video "x"` | You are in the wrong directory, or the file is missing. `kinhin video list` shows what is found; `kinhin video init x` creates it; `--dir PATH` points at another repository. |
| `could not get the video image ghcr.io/...` | The first build pulls about a gigabyte. Check the network, and that the image for your kinhin version is published (a development build of kinhin has no published image: pass `--image` or set `KINHIN_VIDEO_IMAGE`). If the package is private, sign in to the registry with `docker login ghcr.io`. |
| The build starts, then stops with a message from the pipeline | The log above the final line says why: a scene with a missing `id`, an unknown theme (it lists the ones that exist), a clip that is not in the adapter, or a claim your `claims.json` forbids. Fix the config and run it again; unchanged scenes come from the render cache. |
| `read-only file system` or no space left | The image is several gigabytes and a build needs a few more. Free disk space; Apple's `container` keeps its builder cache and images under your home folder, `docker system prune` frees Docker's. |
| `kinhin video music search` says the library is rate limiting | Anonymous use allows about 20 searches a minute and 200 a day. Wait a minute (or until tomorrow), or set `KINHIN_OPENVERSE_CLIENT_ID` and `KINHIN_OPENVERSE_CLIENT_SECRET` from a free Openverse application for a higher limit. The tracks built into the image still show up offline. |
| `add` refuses a track: `is licensed ..., which kinhin does not put in a video` | Only CC0 and public domain (and CC BY with `--license cc-by`) are accepted. Non-commercial, no-derivatives and share-alike tracks are never added. Pick another result. |
| `add` says `which video?` or `there is no video` | Name the video with `--video <name>` when the folder has several, or run `kinhin video init` first. `--no-config` only downloads the track. |
| `did not download the track` | The file is larger than 50 MB, is not mp3, m4a, wav, flac or ogg, is not served over https, or the source link is gone. Try another result; `preview` shows the source page. |
| A music file or font is not found | Paths are relative to your repository, which is mounted read-only. Check the path is committed and inside the repository, and the file extension is mp3, m4a, wav, flac or ogg. Fonts go in `.kinhin/videos/fonts/`. |
| `--on-fleet`: `kinhin-video.yml is not on <branch>` | Run `kinhin video init --workflow`, commit and push the file, then try again. It also needs `gh` signed in (`gh auth login`) and a runner with Docker that matches `--runs-on`. |
| You built the image yourself with Apple's `container build` and the suite is empty (`Cannot find module '/work/scripts/...'`) | Apple's `container build` before 1.5.0 copies no files from a directory when the build path passes through a symlink, such as `/tmp` or `/var/folders` ([apple/container#2285](https://github.com/apple/container/issues/2285)). Build from an absolute path that is not under a symlink (your home folder, for example), or upgrade `container`. Docker is not affected, and neither is the published image. |

Still stuck? Run the build again and read the whole log: `kinhin video build` prints the pipeline's own output as it goes, and `kinhin doctor` checks your container runtimes.
