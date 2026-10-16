# Add videos to your project

Make a narrated launch video, a feature clip or a README GIF for **your own product**. The video is a config file in your
repository: scenes, a voice-over, music, captions and a theme. One command turns it into an MP4, a WebM, a poster, a GIF
and a caption file. Everything runs in a container, on open-source tools, with no accounts.

[← Back to README](../README.md) · [Video gallery](video-gallery.md) · [Marketing video in CI](ci-video.md)

## Your first video in 5 minutes

**You need:**

- **kinhin installed** ([Install & updates](install.md)).
- **A container runtime**: Apple's `container` (`brew install container && container system start`) or Docker. kinhin uses
  Apple's if it is running, otherwise Docker. `--runtime` picks one.
- **Disk space.** The first build pulls a container image of about 1 GB and needs a few GB free.

No recording is needed for title, statement, stats, steps, code and the other drawn scenes.

**1. Create a starter video** in your repository:

```bash
cd ~/code/acme
kinhin video init launch
```

This writes `.kinhin/videos/launch.yml` and a `.gitignore` for the output. It never overwrites an existing file.

**2. Change the words.** Open `.kinhin/videos/launch.yml`. It has three drawn scenes, each with narration, and comments that
say what each field does. One scene looks like this:

```yaml
  - id: intro
    type: title
    props: { title: Acme, subtitle: Ship faster }
    narration: Acme helps your team ship faster.
```

Each scene has an `id`, a `type`, `props` (what is shown) and `narration` (what is said). The
[scene types](video-config.md#scene-types) are listed in the config reference.

**3. Check it** without rendering anything. It takes seconds once the image is there:

```bash
kinhin video validate launch
```

It lists every problem with its place in the file (an unknown scene type, a clip the adapter does not have, a claim your
`claims.json` forbids). Fix them and run it again, or go straight to the build.

**4. Build it:**

```bash
kinhin video build launch
```

The first run pulls the image. Later builds reuse it and, once it is pulled, need no network.

**5. Find the video** in `.kinhin/videos/out/launch/`: `launch.mp4`, `launch.webm`, `launch-poster.png`, `launch-hero.gif`
and the caption file `launch.srt`. The folder also holds `music-credit.txt` when a music track needs a credit line.

Next steps: [the config reference](video-config.md) (themes, scenes, captions, music), and
[recordings of your product](video-adapters.md) if you want your app or terminal on screen.

## What to commit

| Commit | Ignore (already in the generated `.gitignore`) |
|---|---|
| `.kinhin/videos/*.yml`: your videos | `.kinhin/videos/out/`: the built files |
| `.kinhin/videos/themes/`, `fonts/`, `adapters/` (with `reference/` clips) | `.kinhin/videos/.cache/`: the render cache |
| `.kinhin/videos/music/` (the audio, if you choose to keep it) | |

Commit the music file and its `.json` record together. If you do not commit the audio, anyone who builds the video,
including CI, must run `kinhin video music add` again, or the build stops with a missing file.

## Words used on these pages

| Word | Meaning |
|---|---|
| **Video** | One config file in `.kinhin/videos/`. It builds to its own folder under `out/`. |
| **Scene** | One part of the video, with its own text and length. Scenes play in order. |
| **Theme** | The look: font, colours, background and the window or laptop frame. Built in or your own. |
| **Narration** | The words the voice-over says for a scene. |
| **Drawn scene** | A scene kinhin draws from its props, such as a title or a list of steps. Needs no recording. |
| **Adapter** | A folder of recordings of your product, used by device and terminal scenes. |
| **Clip** | One recording inside an adapter, such as your app's screen or a terminal session. |

## Commands

| Command | Does |
|---|---|
| `kinhin video init [name]` | Writes a starter `.kinhin/videos/<name>.yml` (default `launch`) and a `.gitignore`. Never overwrites. |
| `kinhin video list` | Lists the videos (`--json` for scripts). |
| `kinhin video validate [name]` | Checks a video without rendering it: the same checks the build makes, plus that its clips and music files exist. `--all` checks every video. Exit 3 when one has a problem. |
| `kinhin video build [name]` | Builds one. `--theme`, `--format`, `--captions on\|off\|all`, `--caption-style`, `--music <track\|file\|off>` change the look for one build. `--fast` is a quicker preview with no WebM. `--quality draft\|standard\|high` sets the encode (`draft` is `--fast`; `high` is slower and larger) and `--fps 24\|30\|60` the frame rate (30 by default). |
| `kinhin video music search <words>` | Finds free music. Then `preview`, `add` and `list`; see [Music](video-config.md#music). |
| `kinhin video theme new <name> --from <theme>` | Starts your own theme file; see [Your own theme](video-config.md#your-own-theme). |

`--format` takes `16:9`, `9:16`, `4:5` or `1:1`. Other options: `--dir PATH` (a repository other than the current
directory), `--runtime container|docker`, and `--image REF` (or `KINHIN_VIDEO_IMAGE`) to run a different image.

## Building on a runner or in CI

`kinhin video build` runs on the Mac you type it on. To build somewhere else, add a pipeline file once and commit it:

```bash
kinhin video init --workflow --runs-on self-hosted,linux   # writes .github/workflows/kinhin-video.yml; commit and push it
kinhin video build launch --on-fleet                       # dispatches it, follows the run, downloads the video
```

`--on-fleet` uses the GitHub CLI (`gh`, signed in with `gh auth login`) and works for GitHub repositories. The runner needs
Docker and a network that can reach ghcr.io; nothing in the workflow needs a secret. `--ref BRANCH` runs it on another branch.
The video is downloaded to `.kinhin/videos/out/` as with a local build.

Other CI systems get a pipeline too. `--ci` picks one (by default the repository's own, detected from its CI files and the
host of its `origin` remote), and `--runs-on` sets the runner labels in that system's terms:

| `--ci` | Pipeline file | Default runner | Start it from |
| --- | --- | --- | --- |
| `gitea`, `forgejo` | `.gitea/workflows/kinhin-video.yml`, `.forgejo/workflows/kinhin-video.yml` | `runs-on: [linux]` | Actions > kinhin video > Run workflow |
| `gitlab` | `.gitlab/kinhin-video.yml`, included from `.gitlab-ci.yml` | `tags: [linux]` | Build > Pipelines > Run pipeline, with `VIDEO_PROJECT` set |
| `bitbucket` | `.kinhin/videos/bitbucket-pipelines.kinhin-video.yml`, to copy into `bitbucket-pipelines.yml` | `self.hosted, linux.shell` | Pipelines > Run pipeline > custom: kinhin-video |
| `azure` | `.azure-pipelines/kinhin-video.yml` | the `kinhin` pool, `demands: [linux]` | a pipeline made from that file |
| `buildkite` | `.buildkite/kinhin-video.yml` | `queue=kinhin` | a pipeline whose steps upload that file |

Each runs the same image with `docker run` and keeps `.kinhin/videos/out` as the `kinhin-video` artifact. `--on-fleet`
starts and downloads the GitHub workflow only: for the other systems, start the pipeline by hand and download the artifact
(running `--on-fleet` there says where to start it).

kinhin's own repository also builds its videos in GitHub Actions on a release or a pull request, opt-in and with no secrets:
see [Marketing video in CI](ci-video.md).

## In the app

The menu bar app has the same thing in a window: on the Fleet tab, **Make a Video…** lets you choose a repository, create or pick
a video in its `.kinhin/videos/`, build it (with a fast-preview option and live output, then **Show in Finder**), and search free
music and add a track to the selected video. It runs the same code as `kinhin video`, so the runtime, the image and every file are
the same.

## Examples

The kinhin repository's [`video/script/examples/`](https://github.com/RabinApps/kinhin/tree/main/video/script/examples) has a dozen
finished videos. Copy one into `.kinhin/videos/` to start from it. Each uses a different theme, format, voice and mix of scenes:
`hello` (the smallest), `scene-tour` (every drawn scene type), `social-teaser` (9:16), `tutorial-chalk`, `code-walkthrough`
and others. [The gallery](video-gallery.md) shows each one. `kinhin-30s` uses kinhin's own adapter, which is built into the image,
so it is a worked example rather than a template for your product.

## Where to go next

| Page | Read it for |
|---|---|
| [Config reference](video-config.md) | The project file, themes, scene types, captions, music, voices |
| [Recordings of your product](video-adapters.md) | Adapters, clips, recording your app or terminal, the claims check |
| [Troubleshooting](video-troubleshooting.md) | The errors you are most likely to see, and what to do |
| [Video gallery](video-gallery.md) | Finished videos, one per theme, caption style and format |
| [Marketing video in CI](ci-video.md) | kinhin's own opt-in CI build |
