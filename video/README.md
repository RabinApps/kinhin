# video/: demo and launch video tooling

A config-driven video builder: a project file (theme, format, typed scenes, narration) becomes a narrated video with
Motion Canvas scenes, framed screen recordings, a local voice, music and captions; plus the record scripts for the
scripted demo fleet. The full guide (the config, themes, scene types, recording, the container build) is
[docs/videos-for-your-project.md](../docs/videos-for-your-project.md) (any product) and [docs/making-a-video.md](../docs/making-a-video.md) (kinhin's own video); `video/scripts/doctor.sh` lists the tools this machine is missing.

| Path | What |
|---|---|
| `shared/resolve.mjs` | Themes, formats and scene types in one place, shared by the scripts and the scenes |
| `src/` | Motion Canvas scene types, rendered one scene at a time |
| `adapters/<name>/` | One product's recorders, tape and committed `reference/` clips: `kinhin` (this repo's product) and `template` (copy it for yours) |
| `sources/web/` | Browser clips (Playwright); a scenario JSON drives them (`adapters/kinhin/scenarios/`) |
| `script/*.json` | A video: theme, format, voice and typed scenes with narration (`launch.json`, `template-demo.json`, and a dozen in `examples/`) |
| `themes/*.json`, `fonts/` | Looks (paper, clean, midnight, blueprint, chalk) and your own fonts |
| `ci.json`, `scripts/video-ci.mjs` | The opt-in CI configuration and its planner (`.github/workflows/video.yml`; docs/ci-video.md) |
| `tests/` | Unit tests (seconds) and end-to-end tests (real builds); `scripts/test.sh` |
| `Dockerfile` | The build image (Apple `container` or Docker), with this folder baked in; published as `ghcr.io/rabinapps/kinhin-video` for `kinhin video build`; `scripts/build.sh --container` builds from the working tree |
| `scripts/` | `build.sh` (one command, host or container), `voice.mjs`, `retime.mjs`, `render-titles.mjs`, `frames.mjs` (`frame-app.sh`, `frame-terminal.sh`), `assemble.mjs`, `project.mjs`, `verify.mjs`, `video-claims-lint.mjs`, `test.sh`, `gallery.mjs`, `adapter.mjs`, `record-clip.mjs` (records any adapter clip), `fetch-music.mjs`, `container-build.sh` (the image's entry point for `kinhin video`), `make-reference.sh`, `record-terminal.sh`, `record-web.sh`, `doctor.sh` |
| `raw/<adapter>/`, `raw/scenes/`, `out/` | Git-ignored recordings, scene renders and outputs |
