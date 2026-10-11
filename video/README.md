# video/: the launch video

Plan: ~70 s, silent with captions, black-and-white ring brand. Built only from open-source tools.

| Clip | Made with | Source |
|---|---|---|
| opening (intro, problem) | [Motion Canvas](https://motioncanvas.io) | `src/opening.ts` |
| app | `screencapture` on the scripted demo fleet | `scripts/record.sh` |
| install / CLI | [VHS](https://github.com/charmbracelet/vhs) | `terminal/install.tape` |
| closing (lanes, outro) | Motion Canvas | `src/closing.ts` |

Final cut: `scripts/export.sh` (ffmpeg) → `out/launch.mp4`, `launch.webm`, `poster.png`, `hero.gif`.

## Steps

1. **App clip** (Mac): `video/scripts/record.sh`. It launches the debug app with `KINHIN_DEMO=launch`
   (`Sources/kinhin-app/Demo/`), a scripted fleet touching no config, Keychain, daemon or forge.
   For auto-zoom and smooth cursor, run the raw take through OpenScreen or Screenize.
   No spare Mac desktop? `video/scripts/record-in-tart.sh [--gui|--vnc|--headless]` does the same inside a
   throwaway Tart VM: `--gui` shows a VM window, `--vnc` has the same desktop with no window (Screen Sharing to
   watch), `--headless` has no desktop, so it runs the demo unit tests and renders offscreen UI captures instead
   of recording. `--help` lists the options and the one-time Screen Recording grant.
2. **Terminal clip** (Mac): `vhs video/terminal/install.tape`. The tape runs the real `kinhin doctor` and `kinhin start`.
3. **Motion Canvas clips**: `cd video && npm install`, then `npm run serve` (opening) or `npm run serve:closing`,
   open http://localhost:9000, set the exporter to *Video (FFmpeg)*, render, and move the file to
   `raw/opening.mp4` / `raw/closing.mp4`.
4. `video/scripts/export.sh`.

Only claim what the repo supports: the real numbers are in `docs/benchmarks.md` (one M1 Max, a sample, not a benchmark),
and Buildkite, Azure Pipelines, Bitbucket and Windows are not supported.
