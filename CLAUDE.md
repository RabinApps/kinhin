# Kinhin: contributor conventions

Single Swift package (Swift 6.4 tools, Swift 6 language mode / strict concurrency, macOS 15+): `KinhinKit` (engine library), `kinhin` (CLI), `kinhin-app` (AppKit menu bar app; forms, wizard, Diagnostics and Logs are SwiftUI hosted in `NSHostingView`, see `Sources/kinhin-app/UI/SwiftUI/`). See `docs/architecture.md` for the target and folder map.

## Build, test, format

```bash
swift build
swift test                        # ~760 XCTest tests, ~2 min; no VMs or network needed
scripts/tsan.sh                   # ThreadSanitizer run (serial); recipe below
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
- Each domain has one error enum conforming to `LocalizedError` with a user-readable `errorDescription`: `ConfigError` (load/parse), `ConfigEditError` (every config editor), `ImageError` (all image preparers), `TartError`/`ContainerManagerError`/`RuntimeWatchError` (runtimes), `GitHubError`/`GiteaError` (forge clients), `EngineError`, `RPCError`/`DaemonError`. Add cases to these instead of creating a new enum per file.
- Best-effort work (cleanup, cache dirs, idempotent teardown) goes through `bestEffort`/`bestEffortAsync` (`Core/BestEffort.swift`), which logs the failure instead of hiding it. Retry transient network failures with `withTransientRetry`.
- `try?` is allowed only for genuinely best-effort work (cache cleanup, cosmetic reads) and carries a short comment saying why ignoring the failure is safe. If a failure changes what the user sees, handle it: log it and surface it.
- No `try!`, `as!`, or force unwraps (`!`) outside tests. Use `guard let` / `if let` or a single documented `preconditionFailure` for true invariants.
- Never swallow `CancellationError`; let it propagate.
- UI: show failures with `AlertKit.present(error:)` (modal) or the form's status label. Never leave a failed user action silent. Load config through `ConfigStore` so a parse error is shown instead of rendering an empty config.
- CLI: failures end through `fail(_:exit:)` or `fail(error)`; `CLIExit` gives the exit code (1 generic, 2 usage, 3 config, 4 runtime/engine, 5 auth), classified from the error via `ErrorCategory` (KinhinKit). Errors and warnings go to stderr; stdout carries only command output (so `--json` stays parseable).

## Commits

Keep mechanical changes (moves, renames, formatting) in separate commits from behavior changes. `swift build` and `swift test` must pass on every commit.
