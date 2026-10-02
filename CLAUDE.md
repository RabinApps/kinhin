# CLAUDE.md

Instructions for Claude Code in this repo. The human contributor guide, with the build, test, format, layout, style,
error-handling and commit conventions, is [CONTRIBUTING.md](CONTRIBUTING.md). Read it before changing code and follow it
exactly; do not duplicate its rules here.

## Working in this repo

- Before saying a change is done, run `swift build`, `swift test` and `swift format lint --strict -r Sources Tests`. Run
  `scripts/tsan.sh` when touching shared state, actors, locks or anything `nonisolated(unsafe)`.
- Run `bash scripts/docs-lint.sh` and `cd website && npx vitepress build` after editing `docs/` or `website/`.
- The test suite takes about 2 minutes and needs no VMs or network. Never run `swift test --parallel` under TSan.
- Build the release app with `swift build -c release --product kinhin-app`; `KinhinTestSupport` is testable-only.
- Use `scripts/dev-run.sh` to run the debug app; it signs with a stable identity so Keychain "Always Allow" survives
  rebuilds.
- Keep mechanical changes (moves, renames, formatting) in separate commits from behavior changes.
- Docs live once, in `docs/`; `website/` holds only site-only pages. Don't copy a guide into `website/`.
- Adding a forge: follow [docs/adding-a-forge.md](docs/adding-a-forge.md) step by step.
- Don't commit or push unless asked.
