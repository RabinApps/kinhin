# video/: demo and launch video tooling

Motion Canvas title scenes, record scripts for the scripted demo fleet, a VHS terminal tape and an ffmpeg export script.
The full guide (running the demo, writing a script, recording, rendering, exporting) is
[docs/making-a-video.md](../docs/making-a-video.md); `video/scripts/doctor.sh` lists the tools this machine is missing.

| Path | What |
|---|---|
| `src/content.ts` | Words and facts in the title scenes; edit per release |
| `src/` | Motion Canvas scenes (`opening`, `closing` projects) |
| `presets/` | Which clips make a video: `native-app`, `web-product` |
| `sources/web/`, `scenarios/` | Browser clips (Playwright), and the scenario JSON that drives them |
| `demos/example.json` | A demo fleet script to copy |
| `scripts/` | `make.sh`, `export.sh`, `record.sh`, `record-in-tart.sh`, `record-web.sh`, `doctor.sh` |
| `terminal/` | VHS tapes |
| `raw/`, `out/` | Git-ignored clips and outputs |
