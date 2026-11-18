# CLAUDE.md

Instructions for Claude Code in this repo. The human contributor guide, with the build, test, format, layout, style,
error-handling and commit conventions, is [CONTRIBUTING.md](CONTRIBUTING.md). Read it before changing code and follow it
exactly; do not duplicate its rules here.

## Working in this repo

- Before saying a change is done, run `scripts/check.sh` — build, test, format lint, docs lint, docs-sync `--check`,
  skills lint, all CI-parity and failing fast (tests run with `--parallel`; `--fast` skips the ~5 min test run while
  iterating; `--serial` runs them one at a time). Run
  `scripts/tsan.sh` when touching shared state, actors, locks or anything `nonisolated(unsafe)`.
- After editing `docs/` or `website/`, also run `scripts/website-check.sh` (content pipeline, typecheck, tests and a Next.js build; fails on dead links). Don't
  hand-edit between `docs-sync` markers: `scripts/docs-sync.sh` regenerates those blocks from Swift source.
- The test suite takes about 5 minutes with `--parallel` and needs no VMs or network. Never run `swift test --parallel` under TSan.
- Build the release app with `swift build -c release --product kinhin-app`; `KinhinTestSupport` is testable-only.
- Use `scripts/dev-run.sh` to run the debug app; it signs with a stable identity so Keychain "Always Allow" survives
  rebuilds.
- Keep mechanical changes (moves, renames, formatting) in separate commits from behavior changes.
- Docs live once, in `docs/`; `website/` holds only site-only pages. Don't copy a guide into `website/`.
- Adding a forge: follow [docs/adding-a-forge.md](docs/adding-a-forge.md) step by step.
- `skills/` is shipped product surface (agent skills for *using* kinhin), not contributor docs — see "Skills" in
  CONTRIBUTING.md before editing it; `scripts/skills-lint.sh` gates it.
- Desktop app UI changes (`Sources/kinhin-app`) start in the design: update `design/kinhin-app.fig` first, then implement
  from it and compare against it — see "Design first" in CONTRIBUTING.md.
- Don't commit or push unless asked.
- Whenever you change what the launch video shows or says (`video/script/launch.json`, `video/adapters/kinhin/`, the
  app clip, the terminal tapes, the music) or the app UI it records, rebuild it and copy the result into
  `website/public/` (`launch.mp4`, `launch.webm`, `launch-poster.png`) in the same PR. The site must never show an old
  version of the app. See "The site" in docs/making-a-video.md.
- Never burn captions into kinhin's own videos (launch, examples, any `kinhin` adapter build): leave `captions.burn` false and
  don't pass `--captions on|all`; the `.srt` is still written. See docs/making-a-video.md.
