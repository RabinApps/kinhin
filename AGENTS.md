# Working on kinhin as an AI agent

This file is the entry point for coding agents that do not read `CLAUDE.md`
(Codex, Cursor, Gemini, Copilot, Aider, …). Claude Code reads `CLAUDE.md`,
which points at the same two sources. **Nothing is maintained only here**: the
contributor guide is `CONTRIBUTING.md` — read it before changing code and
follow it exactly. This file only tells you how to verify and where to look.

## The gate: `scripts/check.sh`

Before saying any change is done, run:

```bash
scripts/check.sh          # build + test (--parallel) + format lint + docs lint + docs sync + skills lint
scripts/check.sh --fast   # same, skips the ~5 min test run (iterate with this, finish with the full run)
scripts/check.sh --serial # tests serially (rules out a parallel-only failure)
```

It runs exactly what CI runs (`.github/workflows/ci.yml`), failing fast with
file/line annotations. Additional gates, run when they apply:

- `scripts/tsan.sh` — required when you touch shared state, actors, locks, or
  anything `nonisolated(unsafe)` (serial ThreadSanitizer run, ~5–10 min; never
  `swift test --parallel` under TSan).
- `cd website && npx vitepress build` — required when you edit `docs/` or
  `website/`; it fails on dead links.

Single-suite iteration during development:

```bash
swift test --filter StatusDocumentTests
swift format lint --strict -r Sources Tests   # or: swift format format -i -r Sources Tests
```

## Map

- `Sources/KinhinKit/` — engine library, grouped by domain (`Core`, `Config`,
  `Fleet`, `Forges`, `Runtimes`, `Images`, `Setup`, `Update`, `Cache`). No
  AppKit here; UI lives only in `kinhin-app`.
- `Sources/kinhin/` — CLI. Routing table in `Commands/CLICommand.swift`,
  command bodies in `Commands/`, help screen in `Commands/HelpText.swift`.
- `Sources/kinhin-app/` — menu bar app; `AppState/` holds the `@Observable`
  controllers, UI under `UI/SwiftUI/`.
- `Tests/` — `KinhinKitTests` mirrors source folders; shared doubles live in
  `KinhinTestSupport` and every double has a `*ContractTests` in
  `Tests/KinhinKitTests/TestSupport/`.
- `docs/` — the single source for guides and the website (VitePress reads
  `docs/` in place). Never copy a guide into `website/`.
- `skills/` — shipped product surface (agent skills for *using* kinhin), not
  contributor docs. Linted by `scripts/skills-lint.sh`.

## Rules that bite if you miss them

- Layout, style, concurrency, error handling, and commit conventions are in
  `CONTRIBUTING.md`. One primary type per file, named after the file; files
  over ~400 lines are a smell; access control defaults to `internal`.
- Never edit between `<!-- docs-sync:begin … -->` markers — those blocks are
  generated from Swift source by `scripts/docs-sync.sh`.
- Never run `scripts/dev-run.sh` under launchd or a process supervisor (the
  script refuses without a TTY); never `swift test --parallel` under TSan.
- `swift build` and `swift test` must pass on **every** commit; keep
  mechanical changes (moves, renames, formatting) in separate commits from
  behavior changes.
- Adding a forge: follow `docs/adding-a-forge.md` step by step — it is written
  for agents.
- Do not commit or push unless explicitly asked.
