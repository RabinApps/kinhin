# Kinhin: contributor conventions

Single Swift package (Swift 5.9 tools, macOS 13+): `KinhinKit` (engine library), `kinhin` (CLI), `kinhin-app` (AppKit menu bar app). See the Architecture section of `README.md` for the target and folder map.

## Build, test, format

```bash
swift build
swift test                        # ~760 XCTest tests, ~2 min; no VMs or network needed
swift format lint --strict -r Sources Tests
swift format format -i -r Sources Tests
```

Formatting is configured in `.swift-format` (4 spaces, 120 columns). Run the formatter before committing; CI lints with `--strict`.

## Layout

- One primary type per file, named after the file. Small, tightly related types (an error enum, a DTO) may share it. Extensions that add a concern go in `Type+Concern.swift`.
- Files over ~400 lines are a smell: split by responsibility (model / parsing / IO / UI), not by line count.
- `KinhinKit` is grouped by domain (`Core`, `Config`, `Fleet`, `Forges`, `Runtimes`, `Images`, `Setup`, `Update`, `Cache`). It has no AppKit dependency. UI code lives only in `kinhin-app`.
- Tests mirror the source folders (`Tests/KinhinKitTests/Config/…`). Shared fakes and stubs live in the test-support target, never as private copies inside a test file.

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
- Each domain has one error enum conforming to `LocalizedError` with structured cases (associated values, not preformatted strings) and a user-readable `errorDescription`: `ConfigError`, `RuntimeError`, `ImageError`, `ForgeError`, `EngineError`, `RPCError`.
- `try?` is allowed only for genuinely best-effort work (cache cleanup, cosmetic reads) and carries a short comment saying why ignoring the failure is safe. If a failure changes what the user sees, handle it: log it and surface it.
- No `try!`, `as!`, or force unwraps (`!`) outside tests. Use `guard let` / `if let` or a single documented `preconditionFailure` for true invariants.
- Never swallow `CancellationError`; let it propagate.
- UI: show failures with `AlertKit.present(error:)` (modal) or the form's status label. Never leave a failed user action silent. Load config through `ConfigStore` so a parse error is shown instead of rendering an empty config.
- CLI: throw `CLIError`; the entry point maps it to an exit code (1 generic, 2 usage, 3 config, 4 runtime/engine, 5 auth). Errors and warnings go to stderr; stdout carries only command output (so `--json` stays parseable).

## Commits

Keep mechanical changes (moves, renames, formatting) in separate commits from behavior changes. `swift build` and `swift test` must pass on every commit.
