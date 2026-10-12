# video/: demo and launch video tooling

A config-driven video builder: a project file (theme, format, typed scenes, narration) becomes a narrated video with
Motion Canvas scenes, framed screen recordings, a local voice, music and captions; plus the record scripts for the
scripted demo fleet. The full guide (the config, themes, scene types, recording, the container build) is
[docs/making-a-video.md](../docs/making-a-video.md); `video/scripts/doctor.sh` lists the tools this machine is missing.

| Path | What |
|---|---|
| `shared/resolve.mjs` | Themes, formats and scene types in one place, shared by the scripts and the scenes |
| `src/` | Motion Canvas scene types, rendered one scene at a time |
| `sources/web/`, `scenarios/` | Browser clips (Playwright), and the scenario JSON that drives them |
| `demos/example.json` | A demo fleet script to copy |
| `script/*.json` | A video: theme, format, voice and typed scenes with narration (`launch.json`, `example.json`) |
| `themes/*.json`, `fonts/` | Looks (paper, clean, midnight, blueprint, chalk) and your own fonts |
| `reference/` | Small committed app and terminal clips, so the video builds without a Mac |
| `Containerfile` | The build image (Apple `container` or Docker); `scripts/build.sh --container` |
| `scripts/` | `build.sh` (one command, host or container), `voice.mjs`, `retime.mjs`, `render-titles.mjs`, `frames.mjs` (`frame-app.sh`, `frame-terminal.sh`), `assemble.mjs`, `project.mjs`, `fetch-music.sh`, `make-reference.sh`, `record.sh`, `record-in-tart.sh`, `record-web.sh`, `doctor.sh` |
| `terminal/` | VHS tapes |
| `raw/`, `out/` | Git-ignored clips and outputs |
