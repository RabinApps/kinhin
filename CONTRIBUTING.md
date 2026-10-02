# Contributing

kinhin is built by one developer, and bug reports, feature requests and pull requests are welcome. `swift build` and
`swift test` need no VMs or network. The package layout is in [docs/architecture.md](docs/architecture.md).

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
swift build
swift test                        # ~1200 XCTest tests, ~2 min; no VMs or network needed
scripts/tsan.sh                   # ThreadSanitizer run (serial); recipe below
scripts/dev-run.sh                # debug app, signed with a stable identity so Keychain "Always Allow" survives rebuilds
swift package --disable-sandbox dev   # same, as a SwiftPM command plugin (Plugins/Dev)
scripts/dev-run.sh --env-tokens   # debug app with tokens from env vars (.env.dev) instead of the Keychain
swift format lint --strict -r Sources Tests
swift format format -i -r Sources Tests
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

## Layout

- One primary type per file, named after the file. Small, tightly related types (an error enum, a DTO) may share it. Extensions that add a concern go in `Type+Concern.swift`.
- Files over ~400 lines are a smell: split by responsibility (model / parsing / IO / UI), not by line count.
- `KinhinKit` is grouped by domain (`Core`, `Config`, `Fleet`, `Forges`, `Runtimes`, `Images`, `Setup`, `Update`, `Cache`). It has no AppKit dependency. UI code lives only in `kinhin-app`.
- Docs: `docs/` is the single source for the guides and for the website. The VitePress site (`website/`) reads `docs/` in place (`srcDir` and `rewrites` in `website/.vitepress/config.ts`) and rewrites GitHub-style relative links while rendering. Edit a guide once, in `docs/`. `website/` holds only site-only pages (quick start, config, troubleshooting, CLI, home). A new `docs/` page is published by default (add it to the sidebar), or list it in `srcExclude` and `unpublished` (`docsLinks.ts`) to keep it GitHub-only. Check with `cd website && npx vitepress build`, which fails on dead links. Per-forge API notes live in `docs/forges/`. Adding a forge? Follow [docs/adding-a-forge.md](docs/adding-a-forge.md).
- Kit tests mirror the source folders (`Tests/KinhinKitTests/Config/…`); one test class per file, named after its subject (no grab-bag `MiscTests`).
- Shared doubles live in the `KinhinTestSupport` target (`Tests/KinhinTestSupport`): `FakeShell` (queued responses, `failOn`/`failAll`, records `calls`), `FakeTart`, `FakeGitHub`, `FakeSSH`, `StubProtocol`, `makeTestStore()`/`makeTestConfig()`. Import it with `@testable import KinhinTestSupport`. Only keep a private double in a test file when it models behavior specific to that test (e.g. a stateful docker CLI).
- `KinhinTestSupport` is testable-only: release builds must name their products (`swift build -c release --product kinhin-app`).

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

## Commits

Keep mechanical changes (moves, renames, formatting) in separate commits from behavior changes. `swift build` and `swift test` must pass on every commit.

Before opening a PR, also run `bash scripts/docs-lint.sh` if you touched docs.

## Add your project to the list

Running kinhin in your project or company? See [docs/used-by.md](docs/used-by.md).

## Docs versions

The site at `/` is built from `main`. A release is snapshotted under `/<tag>/` (with a version picker in the nav):
after tagging a release, add its tag (for example `"v0.1.0"`) to the top of `website/versions.json` and push. The docs
workflow builds each listed tag from its own `docs/` and `website/` with `DOCS_VERSION=<tag>`, so a snapshot never
changes when `main` does. Tags cut before the picker existed (such as `v0.0.1-beta-1`) cannot be built this way.
