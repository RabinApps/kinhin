# Contributing

kinhin is built by one developer with a bunch of help from AI. Bug reports, feature requests and pull requests are welcome. `swift build` and
`swift test` need no VMs or network. The package layout is in [docs/architecture.md](docs/architecture.md).

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

Not writing code? You can also [add your project to the list](docs/used-by.md) of who uses kinhin, or
[support the project](docs/support.md).

Single Swift package (Swift 6.2 tools, Swift 6 language mode / strict concurrency, macOS 15+): `KinhinKit` (engine
library), `kinhin` (CLI), `kinhin-app` (AppKit menu bar app; `AppState/` holds the `@Observable`
`FleetController`/`UpdateController`, and the main window, tabs, forms, wizard, Diagnostics and Logs are SwiftUI hosted
in one `NSHostingView`, see `Sources/kinhin-app/UI/SwiftUI/`).

## Requirements

Full Xcode 26 or later (Swift 6.2+), not only the Command Line Tools: `swift test` needs XCTest, which ships with
Xcode. If the build stops with `unable to resolve module dependency: 'XCTest'`, point the toolchain at Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app    # or: export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

A standalone swift.org or mise toolchain works only together with Xcode's SDK for the same reason. The self-hosted CI
runner is a kinhin-provisioned Tart VM, so its base image must include Xcode (for example
`ghcr.io/cirruslabs/macos-tahoe-xcode:latest`); see [Toolchains](docs/toolchains.md). The CI "Check toolchain" step
fails fast with this hint.

## Build, test, format

```bash
scripts/check.sh                  # everything CI runs, in one command, failing fast (build, test,
                                  # format lint, l10n lint, docs lint, docs-sync --check, skills lint)
scripts/check.sh --fast           # same, skips the ~2 min test run — iterate with this
swift build
swift test                        # ~2300 XCTest tests, ~2 min; no VMs or network needed
scripts/tsan.sh                   # ThreadSanitizer run (serial); recipe below
scripts/e2e.sh                    # end-to-end suite against real forges and runners; see docs/e2e-testing.md
scripts/l10n-lint.sh              # String Catalog vs. the app's sources; --sync adds/drops entries
scripts/dev-run.sh                # debug app, signed with a stable identity so Keychain "Always Allow" survives rebuilds
swift package --disable-sandbox dev   # same, as a SwiftPM command plugin (Plugins/Dev)
scripts/dev-run.sh --env-tokens   # debug app with tokens from env vars (.env.dev) instead of the Keychain
```

**Always run the debug app from a terminal.** Do not run `scripts/dev-run.sh` via
launchd (`launchctl submit`), an Xcode scheme, or any other process supervisor.
launchd restarts the script every time the app exits, creating an infinite loop.
The script now detects non-terminal runs (no TTY) and exits with an error instead.
If a restart loop ever gets going, run `launchctl remove kinhin-dev-app` to stop it.

`scripts/dev-run.sh` signs the build with a stable identity (your first Apple Development certificate, or
`CODESIGN_IDENTITY`) so the Keychain's **Always Allow** answer survives rebuilds instead of prompting after every one.
Extra arguments go to the app, e.g. `scripts/dev-run.sh -kinhin.autoStartFleet NO` overrides the auto-start preference
for that run only. `swift package --disable-sandbox dev` does the same from the repo root (the sandbox must be off
because it signs and launches the app); arguments pass through.

With `--env-tokens`, forge tokens are read from environment variables (`KINHIN_TOKEN_GITHUB`, `KINHIN_TOKEN_GITEA`, …,
and `KINHIN_TOKEN_<ACCOUNT>` for named accounts, upper-cased with non-alphanumerics as `_`), loaded from a gitignored
`.env.dev` (copy `.env.dev.example`). The same works for the CLI: `KINHIN_TOKEN_STORE=env KINHIN_TOKEN_GITHUB=… swift
run kinhin auth status`. Tokens typed into the app in this mode last for that run only. It exists only in debug builds;
release builds always use the Keychain.

```bash
swift format lint --strict -r Sources Tests
swift format format -i -r Sources Tests
bash scripts/skills-lint.sh       # skills/*/SKILL.md frontmatter + command drift (in check.sh too)
```

Formatting is configured in `.swift-format` (4 spaces, 120 columns). Run the formatter before committing; CI lints with `--strict`.

### ThreadSanitizer testing (scripts/tsan.sh)

Run `scripts/tsan.sh` when touching shared state, actors/locks, or anything `nonisolated(unsafe)`.
The script is `swift test --sanitize thread` (debug, ~5–10 min) and never `--parallel`:

- **Serial only.** Under TSan, `--parallel` makes the worker bundles collide on the tests' fixed
  temp paths (e.g. `UpdateCheckTests`' version-named DMG in a shared temp dir): suites fail at
  random, and the default target can exit 0 while other bundles are still mid-run. Serial is the
  only stable mode.
- **Exit code ≠ test result.** TSan aborts the run at exit the moment it holds a report, so a
  target whose tests all pass still exits 1. Read the script's summary: test failures with no
  sanitizer reports are a regression; reports mean a race, and the script fails on any report —
  there is no tolerated-race list. The stubs that swap global behavior across threads
  (`StubProtocol.handler`) keep their storage behind a `Mutex`, which is what keeps the run
  clean; give any new test global the same treatment instead of `nonisolated(unsafe)`.

### End-to-end tests (scripts/e2e.sh)

`swift test` proves kinhin agrees with its fakes; `Tests/E2E` proves the fakes agree with reality. It is a **separate
Swift package** (Swift Testing, driving the real `kinhin` binary) so `swift test` and `scripts/check.sh` never load it,
and it is **not part of per-PR CI**: it runs real forges in containers and real jobs in real guests on a dedicated Mac
(`.github/workflows/e2e.yml`). Run `scripts/e2e.sh` (seconds, no Docker) while iterating on CLI or security behavior,
and `scripts/e2e.sh --local` before changing forge registration, runtimes, the engine or the runner scripts. See
[docs/e2e-testing.md](docs/e2e-testing.md) for the tiers, switches and what each suite proves.

- **A fake that disagrees with the real thing is a bug in the fake.** When an e2e run finds one, fix the product, then
  fix the unit test that pinned the wrong behavior, and add a regression test at the unit level too.
- **Adding a forge or a CLI command** fails `CoverageTests` until you classify it there. That is the point.
- The e2e suite sandboxes itself with `KINHIN_SUPPORT_DIR` (support files, daemon socket) and the debug-only
  `KINHIN_TOKEN_STORE=env`; it never touches your real config or Keychain.

## Layout

- One primary type per file, named after the file. Small, tightly related types (an error enum, a DTO) may share it. Extensions that add a concern go in `Type+Concern.swift`.
- Files over ~400 lines are a smell: split by responsibility (model / parsing / IO / UI), not by line count.
- `KinhinKit` is grouped by domain (`Core`, `Config`, `Fleet`, `Forges`, `Runtimes`, `Images`, `Setup`, `Update`, `Cache`, `Benchmarks`). It has no AppKit dependency. UI code lives only in `kinhin-app`.
- Docs: `docs/` is the single source for the guides and for the website. The VitePress site (`website/`) reads `docs/` in place (`srcDir` and `rewrites` in `website/.vitepress/config.ts`) and rewrites GitHub-style relative links while rendering. Edit a guide once, in `docs/`. `website/` holds only site-only pages (quick start, config, troubleshooting, CLI, home). A new `docs/` page is published by default (add it to the sidebar), or list it in `srcExclude` and `unpublished` (`docsLinks.ts`) to keep it GitHub-only. Check with `cd website && npx vitepress build`, which fails on dead links. Per-forge API notes live in `docs/forges/`. Adding a forge? Follow [docs/adding-a-forge.md](docs/adding-a-forge.md).
- Kit tests mirror the source folders (`Tests/KinhinKitTests/Config/…`); one test class per file, named after its subject (no grab-bag `MiscTests`).
- Shared doubles live in the `KinhinTestSupport` target (`Tests/KinhinTestSupport`): `FakeShell` (queued responses, `failOn`/`failAll`, records `calls`), `FakeTart`, `FakeGitHub`, `FakeGitea`, `FakeGitLab`, `FakeSSH`, `DockerFakingShell` (stateful `docker ps/run/start/rm`, queued `ps`/`exec` answers), `StubProtocol`, `makeTestStore()`/`makeTestConfig()`. Import it with `@testable import KinhinTestSupport`. Only keep a private double in a test file when it models behavior specific to that test (e.g. `KeygenShell`, the recording shell `GuestSSHKeyTests` needs).
- Every shared double gets a contract test in `Tests/KinhinKitTests/TestSupport/` named `<Double>ContractTests`, pinning the fake to the real implementation it stands in for: forge fakes run against the real client over `StubProtocol` (same requests, same error cases, same read shapes), `FakeShell` against the real `Shell` over `/bin` tools. The point is drift detection — when the real implementation changes behavior, the contract test fails instead of the fake silently staying stale. Adding a new double to `KinhinTestSupport`? Add its `<Double>ContractTests` in the same change. The rule extends to doubles outside `KinhinTestSupport`: any private double that impersonates a real implementation (a faking shell, an app-service fake) gets a `<Double>ContractTests` in its own test target — see `FakeDockerContractTests` and `FakeFleetServingContractTests` (`Tests/KinhinAppTests/`) and `KeygenShellContractTests` (kit). Spies and fault injectors that only observe or break one test stay private and are asserted by the suite they serve.
- `KinhinTestSupport` is testable-only: release builds must name their products (`swift build -c release --product kinhin-app`).

## Skills

`skills/<name>/SKILL.md` files are shipped product surface — the agent skills for _using_ kinhin — published through
`.claude-plugin/plugin.json`, with `.claude-plugin/marketplace.json` making the repo a one-command Claude Code
marketplace (`claude plugin marketplace add RabinApps/kinhin`). They are not contributor docs (those live in `docs/`);
edit them only when the CLI or a workflow an agent needs changes.

- The frontmatter `name:` must equal the directory name, and `description:` must be non-empty: that line is what an
  agent's skill matcher reads to decide when to load the skill, so it must name the situations, not the commands.
- Every backticked `kinhin <command>` must be a command the CLI actually routes and the help screen documents.
  `bash scripts/skills-lint.sh` fails on drift (it runs in `scripts/check.sh` and the CI docs job). A renamed command
  updates `CommandCatalog.swift` and the skill in the same change.
- Keep the existing style: defer to `kinhin help` when the page and the CLI disagree, and keep the confirm-before-
  destructive-op rules (`cleanup --yes`, `reset`) that keep agents from wiping a user's machine.

## CLI commands

Every command, alias and flag the `kinhin` binary accepts is declared once, in
`Sources/kinhin/Commands/Spec/CommandCatalog.swift` (`CommandSpec` / `FlagSpec`). The resolver parses and validates
against that table (an undeclared command, subcommand or flag is a usage error with a "did you mean"), and the same table
generates `kinhin help`, each `kinhin <command> --help` page and the skills-lint vocabulary.

- **Adding a flag or command:** declare it in the catalog first, then read it in the command body. A test
  (`CommandCatalogTests`) fails when a body reads a flag the catalog does not declare. Keep an old spelling working as a
  hidden alias (`aliases:` / `hidden: true`) instead of removing it; scripts and skills depend on them.
- **Help text:** summaries are one line (about 60 characters) and every help line fits 100 columns. Put long explanations in
  the `docs/` page the command's `docs:` field names, not in the help. After changing the catalog run
  `KINHIN_UPDATE_GOLDEN=1 swift test --filter HelpRendererTests` to refresh `scripts/golden/cli-help.txt` (the copy
  `docs-sync.sh` and `skills-lint.sh` read, since they run without a Swift toolchain), then `scripts/docs-sync.sh`.
- **Exit codes, one rule** (`ExitRule`, `CLIExit`): 0 healthy or done, 1 needs attention (no daemon, a failing check, a token
  not ready), 2 usage error, then 3 config, 4 runtime, 5 auth. A command that reports a state (`status`, `stop`, `pause`,
  `resume`, `setup status`, `auth status`, `doctor`) derives "healthy" from its document and ends through
  `ExitRule.finish(healthy:)`. Do not invent a per-command rule.
- **Machine output:** print documents with `emitJSON(_:)` (one encoder: pretty, sorted keys; opt into `.iso8601` dates only
  for documents that always had them). Under `--json` a failure is `{"error": …, "code": …}` on stdout (`ErrorReporter`),
  so a script parsing stdout always gets JSON. `--quiet` (state commands) prints nothing and leaves the exit code as the
  answer.
- **Secrets:** never take a token as an argument in new code. `auth set|add` read it from the hidden prompt or
  `--token-stdin`; `--token X` stays only as a hidden, warned legacy form.
- **Bare `kinhin`** prints the setup status and the single next step (`BareStatus`, read-only); `kinhin help` prints the
  full screen.

## Style

- Use `// MARK: - Title` (with the dash) to separate sections in any file with more than one concern.
- Types are `UpperCamelCase`, everything else `lowerCamelCase`. YAML/JSON keys that are snake_case are mapped with explicit `CodingKeys`; do not leak snake_case into Swift property names.
- Access control defaults to `internal`. Mark `public` only what `kinhin` or `kinhin-app` actually imports. Tests use `@testable import`.
- Classes are `final` unless subclassing is required. Prefer composition over subclassing view controllers.
- Concurrency: `async/await`. UI classes are `@MainActor` at the class level (no per-method repeats, no `MainActor.run` inside them). Sleep with `Task.sleep(for:)`. Do not add new `DispatchQueue`, semaphores, or raw `NSLock`; use `Mutex` or an actor.
- Logging goes through `Log` (`Log.info/warn/error`) with a subsystem tag. No `print` in `KinhinKit` or the app; the CLI uses `print` only for command output on stdout.
- Dependencies (shell, HTTP session, keychain, paths) are injected through protocols with a production default, so they can be faked in tests.

## Error handling

- Functions that can fail `throw`. Do not return `nil`/`false`/`[]` to mean "it failed".
- Each domain has one error enum conforming to `LocalizedError` with a user-readable `errorDescription`: `ConfigError` (load/parse), `ConfigEditError` (every config editor), `ImageError` (all image preparers), `TartError`/`ContainerManagerError`/`RuntimeWatchError` (runtimes), `GitHubError`/`GiteaError`/`GitLabError`/`BuildkiteError`/`AzureDevOpsError` (forge clients), `EngineError` (also the app's fleet-access errors), `RPCError`/`DaemonError`, `UpdateCheckError`. Add cases to these instead of creating a new enum per file.
- Best-effort work (cleanup, cache dirs, idempotent teardown) goes through `bestEffort`/`bestEffortAsync` (`Core/BestEffort.swift`), which logs the failure instead of hiding it. Retry transient network failures with `withTransientRetry`.
- `try?` is allowed only for genuinely best-effort work (cache cleanup, cosmetic reads) and carries a short comment saying why ignoring the failure is safe. If a failure changes what the user sees, handle it: log it and surface it.
- No `try!`, `as!`, or force unwraps (`!`) outside tests. Use `guard let` / `if let` or a single documented `preconditionFailure` for true invariants.
- Never swallow `CancellationError`; let it propagate.
- UI: show failures with `AlertKit.present(error:)` (modal) or the form's status label. Never leave a failed user action silent. Load config through `ConfigStore` so a parse error is shown instead of rendering an empty config.
- CLI: failures end through `fail(_:exit:)` or `fail(error)`; `CLIExit` gives the exit code (1 generic, 2 usage, 3 config, 4 runtime/engine, 5 auth), classified from the error via `ErrorCategory` (KinhinKit). Errors and warnings go to stderr; stdout carries only command output (so `--json` stays parseable).

## Localization (menu bar app)

English is the only shipped language, but the app is built so that adding a language is translation work, not code
work. All user-facing text lives in one String Catalog, `Sources/kinhin-app/Resources/Localizable.xcstrings` (source
language `en`). SwiftPM compiles it into the app's resource bundle, and `scripts/build-app.sh` hoists the resulting
`<lang>.lproj` folders into `kinhin.app/Contents/Resources` (and lists them in `CFBundleLocalizations`), so SwiftUI
and AppKit resolve them through `Bundle.main`. `scripts/dev-run.sh` copies them next to the debug binary for the same
reason.

**Where text goes**

| Text is…                                                                                                                                                        | Write                                                                                                   |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| a SwiftUI literal (`Text`, `Button`, `Label`, `Toggle`, `Picker`, `.help`, `.accessibilityLabel`, `HintText`, `FormCard(title:subtitle:)`, `StatusText(text:)`) | the plain literal; it is already a `LocalizedStringKey`                                                 |
| built in a model, an `NSMenuItem`, an `NSAlert`, an accessibility string, an App Intent reply                                                                   | `String(localized: "…", bundle: .l10n, comment: "…")`                                                   |
| already localized by a model and handed to a view                                                                                                               | `Text(verbatim:)`, `HintText(verbatim:)`, `StatusText(verbatim:)`, `FormCard(title: Text(verbatim: …))` |
| a log line, identifier, URL, file name or command                                                                                                               | an ordinary string, never localized                                                                     |

- Always pass `bundle: .l10n` (it finds the catalog under `swift run` and `swift test`, where `Bundle.main` is not the
  app) and a `comment:` that tells a translator where the string appears and what each placeholder is.
- One whole sentence per string. Interpolate (`"Delete \(id)?"` becomes the key `Delete %@?`); never join fragments
  (`"Delete " + id + "?"`) or splice a phrase into a template. Give each variant its own key (`"Started."` /
  `"Stopped."`) so a language can reorder and re-inflect freely.
- Never branch on displayed text (`text.hasPrefix("Failed")`); keep a state flag next to the string.
- Plurals are catalog variations, not `n == 1 ? "" : "s"`: write `"\(n) runners"`, give the entry English
  `one`/`other` forms in the catalog and put "plural by <what is counted>" in its comment (the lint checks for the
  variations). A string with a second number uses a substitution on the counted argument; see
  `%lld instances · %lld busy` in the catalog for the shape.
- Dates, durations, sizes and lists go through formatters, never hand-built English: `AppFormat.duration` / `.bytes` /
  `.relative` (`DateComponentsFormatter`, `ByteCountFormatter`, `RelativeDateTimeFormatter`), `Date.formatted`,
  `.formatted(.percent)`, and `.formatted(.list(type: .and))` for name lists.
- Product and tool names (`kinhin`, `tart`, `Docker`), commands, config keys and example URLs stay verbatim inside the
  translated sentence; say so in the comment.

**The lint.** `scripts/l10n-lint.sh` (a `scripts/check.sh` stage, and part of `swift test` as `L10nCatalogTests`)
fails when a localized literal has no catalog entry, an entry is stale, a plural entry lacks plural variations, a
translation changes its placeholders, or a sentence-like literal sits outside every localizing call (new hard-coded
English in view or AppKit code). After adding, changing or deleting a string, run `scripts/l10n-lint.sh --sync`: it adds
the missing keys (with a generated comment you should improve) and drops stale ones, and never touches existing
translations or comments. The scanner is a small lexer, not a compiler; it picks `%lld` for numeric interpolations from a
name list (`L10nSourceScanner.numericNames`), so extend that list when a new numeric value is interpolated.

**Trying a pseudo-locale.** Run the debug app with Apple's pseudo-localization flags to spot strings that bypass the
catalog and layouts that break when text grows:

```bash
scripts/dev-run.sh -NSDoubleLocalizedStrings YES                 # every localized string doubled: clipped or overflowing layouts
scripts/dev-run.sh -NSShowNonLocalizedStrings YES                # strings that miss a catalog lookup are logged and upper-cased
scripts/dev-run.sh -AppleLanguages "(en-XA)"                     # Xcode's accented pseudo-language, once a second language is bundled
```

Plain English still showing under `-NSDoubleLocalizedStrings` is hard-coded or comes from KinhinKit (below). The bundled
app takes the same flags: `open dist/kinhin.app --args -NSDoubleLocalizedStrings YES`.

**Adding a language** (once the strings are final): nothing changes in `Package.swift` (`defaultLocalization` is `en`).
Open the catalog in Xcode (or add `localizations.<lang>` entries by hand), translate every key including the plural
forms, and run `scripts/build-app.sh`: the new `<lang>.lproj` is bundled and registered automatically.
`testTranslationsKeepThePlaceholdersOfTheirKey` guards the placeholders.

**Not covered yet.** Text that originates in `KinhinKit` (the fleet status line, `LocalizedError.errorDescription`s,
doctor and setup check titles and details, pipeline timing, runtime health notes, support-link blurbs) reaches the app as
ready-made English `String`s and is shown as is, and the CLI is English only; both belong to later phases of
[docs/plans/multi-locale.md](docs/plans/multi-locale.md). `docs/`, `website/` and `skills/` are English-only by policy.

## Brand assets

The logo (a black ring on white) lives in `assets/brand/`. The iconset, `AppIcon.icns` and the website favicons,
touch icon and social image are generated: edit the geometry in `scripts/make-icons.swift`, run
`swift scripts/make-icons.swift`, and commit the output. Don't hand-edit generated files.

## Commits

Keep mechanical changes (moves, renames, formatting) in separate commits from behavior changes. `swift build` and `swift test` must pass on every commit.

Before opening a PR, run `scripts/check.sh`; it includes `bash scripts/docs-lint.sh` and `bash scripts/docs-sync.sh
--check`, which you must also run if you touched docs or any code they are generated from. When you edit `docs/` or
`website/`, verify the site with `cd website && npx vitepress build` (fails on dead links).

## Cutting a release

The full procedure — Developer ID signing, notarization credentials, the local rehearsal run, and the
tag publish — is in [docs/releasing.md](docs/releasing.md). In short: run `scripts/changelog.sh promote <version>`,
bump `Sources/KinhinKit/Core/Version.swift`, and commit both together; then run `scripts/check.sh`, then
`scripts/release.sh <version>`. It builds and verifies everything a tag publish would, and prints the tag commands
when you are ready. The script never commits, tags or pushes.

User-visible changes go under `## Unreleased` in `CHANGELOG.md` in the same PR (see the pull request checklist).
`scripts/changelog.sh check` validates the heading structure.

## Generated doc blocks

Some docs are derived from code, so they are generated instead of hand-copied: the forge IDs (`docs/forges/README.md`), the daemon RPC methods (`docs/architecture.md`), and the CLI exit codes and `kinhin help` screen (`website/cli/commands.md`). Each sits between `<!-- docs-sync:begin NAME -->` and `<!-- docs-sync:end NAME -->` markers. Never edit between the markers; change the Swift source (`ForgeID`, `RPCMethod`, `CLIExit`, `CommandCatalog`; for the help screen also refresh `scripts/golden/cli-help.txt`, see "CLI commands"), then run:

```sh
scripts/docs-sync.sh           # rewrite stale blocks in place
scripts/docs-sync.sh --check   # change nothing, diff and exit 1 if stale (CI runs this)
scripts/docs-sync.sh --list    # show each block and the file that holds it
```

To add a block, write a `gen_<name>` function in `scripts/docs-sync.sh`, add a `<name>|<file>` row to its `blocks` list, and put the marker pair in that file. The generators read Swift with grep/sed/awk, so they need no toolchain. If one reports no output, the Swift source changed shape; update the generator. Facts the script can't derive (defaults quoted in prose, config keys) are still hand-maintained; `scripts/docs-lint.sh` catches known-stale strings only.

## Add your project to the list

Running kinhin in your project or company? See [docs/used-by.md](docs/used-by.md).

## Docs versions

The site at `/` is built from `main`. A release is snapshotted under `/<tag>/` (with a version picker in the nav):
after tagging a release, add its tag (for example `"v0.1.0"`) to the top of `website/versions.json` and push. The docs
workflow builds each listed tag from its own `docs/` and `website/` with `DOCS_VERSION=<tag>`, so a snapshot never
changes when `main` does.
