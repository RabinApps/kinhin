---
title: How to make a product launch video from code
description: Keep a launch video's script in your repo as YAML. kinhin renders narration, captions and music into an MP4, WebM, poster and GIF on each build.
head:
  - - link
    - rel: canonical
      href: https://kinhin.dev/how-to-make-a-product-launch-video-from-code.html
---

# How to make a product launch video from code

Write the video as a config file in your repository: the scenes, a voice-over, music, captions and a theme. One command
renders it into an MP4, a WebM, a poster image, a GIF and a caption file. Because the video is built from the repo, the next
release can rebuild it instead of someone re-editing a timeline.

## Steps

1. **Create a starter video.** Run `kinhin video init launch` in your repository. It writes a starter config under
   `.kinhin/videos/`.
2. **Write the scenes.** Title, statement, stats, steps and code scenes are drawn, so they need no screen recording. The
   [video config reference](/guide/video-config) lists every scene and setting.
3. **Build it.** Run `kinhin video build launch`. Flags change the theme, format, captions and music for one build.
4. **Find the output.** It lands in `.kinhin/videos/out/launch/`: `launch.mp4`, `launch.webm`, `launch-poster.png`,
   `launch-hero.gif` and the caption file.

## What you need

- A container runtime. kinhin uses Apple's `container` if it is running, otherwise Docker.
- Disk space. The first build pulls a container image of about 1 GB.

No accounts are needed. To rebuild the video in CI on every release, see [Marketing video in CI](/guide/ci-video). That is
off by default and opt-in per repository.

For an example, see the [video gallery](/guide/video-gallery). Or read [Add videos to your project](/guide/videos-for-your-project)
for the full walk-through.

<SearchNextSteps />
