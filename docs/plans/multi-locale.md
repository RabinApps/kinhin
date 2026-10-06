# Plan: English + Spanish localization (app, kit, CLI; docs stay English)

## Confirmed decisions

- **Scope:** menu bar app UI, KinhinKit user-facing text, CLI output and help screen — **all** get Spanish.
- **Docs/website/skills: English-only by policy** (no `docs/`, `website/`, or `skills/` content edits besides the plan file and CONTRIBUTING, so no VitePress gate; `docs-lint`, `docs-sync`, and `skills-lint` contracts are untouched).
- **Language selection:** follow the macOS system locale; in-app override picker (System / English / Español) in Settings; `KINHIN_LANG` env var as a programmatic override for CLI, demos, and tests.
- **Mechanism:** Swift string tables in KinhinKit, **key = the English source string**: `L10n.tr("Stop", args…)` looks up the `es` table, formats with locale-aware `String(format:)`, and **passes English through when no entry exists**.

## Core design rules

1. **Translate only at rendering boundaries** — SwiftUI `Text`/`HintText`/`FormCard(title:)`, `NSMenu` items, `AlertKit.present`, CLI human stdout/stderr, `LocalizedError.errorDescription`. Models, `--json` serializers, `Log` lines, `docs/`, `website/`, and `skills/` never call `L10n`, so machine output, logs, and all documentation stay English no matter the locale.
2. **`HelpText.swift` stays a plain English literal** — `scripts/skills-lint.sh` and `scripts/docs-sync.sh` parse it with `sed`; translation happens at print time via a line-keyed map.
3. **Graceful degradation + enforced parity** — unwrapped/untranslated strings render English; a parity test fails the build when a wrapped string lacks a Spanish entry.
4. Format placeholders are POSIX style (`%@`, `%d`, `%lld`); interpolation like `"Install \(tool)?"` is rewritten to `tr("Install %@?", tool)`.

## Phase 0 — Save the plan + core (`KinhinKit/Core`) + test pinning

- **First:** write this plan document to `docs/plans/multi-locale.md` (kebab-case, matching the existing plan docs; `docs/plans/**` is already VitePress-excluded, and the content trips no `docs-lint.sh` stale-string patterns).
- New `Sources/KinhinKit/Core/L10n.swift` (`enum L10n`, one type per file):
  - `Language { english, spanish }`; resolution precedence: programmatic override → `KINHIN_LANG` env → app-injected UserDefaults choice → system `Locale.current` → `.english`.
  - **Test pinning:** when running under XCTest, skip the system-locale step so all ~1200 existing tests stay English on any machine. Verify `XCTestConfigurationFilePath` is present under `swift test`; fallback if not: export `KINHIN_LANG=en` in `scripts/check.sh` before `swift test`.
  - `static func tr(_ english: String, _ args: CVarArg...) -> String` (passthrough fallback, `String(format:locale:)` with `Locale(identifier: "es")`).
  - `Mutex`-guarded override: `setOverride(_:)` / `withLanguage(_:_:)` → **run `scripts/tsan.sh`** (new shared state).
  - Small plural helper (one/other, Spanish rules) for the handful of "N job(s)" strings.
- New `L10n+Spanish…` table files split by domain (respect the ~400-line rule): `L10n+Spanish+Chrome.swift`, `+App.swift` (grows per tab group), `+Kit.swift`, `+CLI.swift`, `+Help.swift`.
- Tests: `Tests/KinhinKitTests/Core/L10nTests.swift` (precedence, format args, passthrough, plural) and `L10nParityTests` — derive package root from `#filePath`, walk `Sources/`, regex-extract every `L10n.tr("…")` literal, assert each has an `es` entry or is in an explicit `untranslated` allowlist, and that placeholders match between key and value.

## Phase 1 — App chrome + language picker

- `AppPreferences.appLanguage(in:)` / `setAppLanguage(_:)` (`.system | .english | .spanish`), mirroring the existing `launchMode` accessors; tests in `AppPreferencesTests`.
- Wrap: `AppDelegate+MainMenu.swift`, `AppDelegate+StatusItem.swift` (`buildMenu()`), `FleetAlert` titles, `AlertKit.present(error:)`, window/tab chrome strings.
- Settings row in `AppSectionView` (next to _Show at launch_): "Language: System / English / Español".
- On change: `L10n.setOverride(...)` → reinstall the main menu, rebuild the status menu, and recreate the window's `NSHostingView` root so every `Text` re-evaluates (a rare, explicit rebuild — far simpler than threading observation through ~400 call sites).
- Commit runs `scripts/tsan.sh` (first Mutex-backed change).

## Phase 2 — App views (one commit per tab group)

- Walk `Sources/kinhin-app/UI/SwiftUI/**`: `Text("…")` → `Text(L10n.tr("…"))`, `HintText`, `FormCard`/`CollapsibleFormCard` titles+subtitles, alert titles built in models, wizard, sheets, Diagnostics rows, `Intents/` display strings where user-visible.
- Interpolated literals become format templates (per the placeholder rule).
- Spanish tables grow per domain file.

## Phase 3 — KinhinKit user-visible text

- 42 `LocalizedError.errorDescription`s → `L10n.tr(template, args…)` (errors are the rendering boundary for both app alerts and CLI `fail`).
- English **models** keep their strings: `SetupStatusComputer`, `DoctorReportBuilder`, `RuntimeInstaller`, `TartHealth`, `TokenRequirements` titles/details are wrapped only where rendered (app Diagnostics/Setup views, CLI human-output prints).
- New tests asserting `doctor --json` and `setup-status --json` output is **byte-identical under a `.spanish` override** (proves rule 1).

## Phase 4 — CLI

- Central printers first: `Sources/kinhin/Commands/Output.swift` (`warn`, `fail(message)`, `fail(error)`) — every usage/config/auth/runtime failure becomes translatable in one place; kit `errorDescription`s are already localized by Phase 3.
- Human output: wrap the ~200 command-output `print` sites with `tr` + format args, **skipping all `--json` branches** (JSON print sites never call `tr`).
- Existing `KinhinCLITests` keep passing via Phase 0 English pinning; add one test asserting a command's human output is Spanish under the override and its `--json` stays English.

## Phase 5 — Help screen

- `HelpText.swift` untouched (sed-based tooling contract preserved; generated docs stay English).
- New `L10n+Help+Spanish.swift`: exact English line → Spanish line; the `help` command maps the rendered screen line-by-line under Spanish, missing lines pass through English.
- Parity test: every help line is either translated or allowlisted; no stale keys after help edits (keeps `skills-lint`/`docs-sync` green).

## Phase 6 — Conventions (CONTRIBUTING only)

- Add a short **Localization** section to `CONTRIBUTING.md`: the render-boundary rule (never localize models, `--json`, `Log`, or markdown), English-as-key style, `%@`/`%d` placeholders, how to add a locale (one table + enum case), and that `L10nParityTests` enforces coverage.
- Record the **docs are English-only** policy in the same section, with the future path if it changes: VitePress `locales` (es `srcDir` + rewrites + per-locale sidebar) plus a page-parity check in `scripts/docs-lint.sh`.
- Spanish app/CLI copy is flagged in commit messages as a **first draft for human review**.

## Verification (each phase)

- `scripts/check.sh --fast` while iterating; full `scripts/check.sh` before finishing (includes format lint, docs lint, docs sync, skills lint — all should be unaffected).
- `scripts/tsan.sh` after Phase 0 (and any later shared-state change).
- `swift format lint --strict -r Sources Tests`.
- Manual spot-check: `KINHIN_LANG=es kinhin doctor` vs `=en` (JSON stays English); run `scripts/dev-run.sh` with an es override to eyeball menus/tabs/alerts and the Settings picker; confirm in-app doc links still open English docs.

## Out of scope

- `docs/` content (other than this plan file), `website/`, `skills/` — English-only by policy (per your decision); revisit only with the VitePress i18n path noted in Phase 6.
- Locales beyond Spanish (adding one = one table + enum case); GNU `LANG`/`LC_MESSAGES` parsing beyond `KINHIN_LANG` (system locale covers macOS users).
