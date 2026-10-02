# Plan: `kinhin toolchains detect` — generate toolchains from a project

## Context
Toolchains are now declared per project (`.kinhin.yml` in the repo, or a `projects:` entry in config.yaml). Writing them by hand means knowing the catalog ids and the "no implicit installs" rule (e.g. `pnpm` or `vercel` fails validation unless `node@22` is also listed). Nothing in the repo scans a local directory today. We add an analyser that inspects a checkout (manifests + CI workflows) and emits a valid `.kinhin.yml` `toolchains:` block, with the evidence behind each pick.

Scope (confirmed): local directory only, output is a repo-side `.kinhin.yml`, CLI only, reads manifests and `.github/workflows`.

## Design

### KinhinKit: `Sources/KinhinKit/Images/ProjectDetection/`
One primary type per file, all `internal` except what the CLI imports.

- `ToolchainDetection.swift` (public): result `{ specs: [String], stacks: [String], evidence: [Finding], unmatched: [String] }`; `Finding { spec, source file, reason }`. `Codable` for `--json`. Has `yaml()` rendering a `.kinhin.yml` string.
- `ProjectToolchainDetector.swift` (public): `detect(at: URL, fileManager/reader injected) throws -> ToolchainDetection`. Reads files through a small `ProjectFileReading` protocol (production default = FileManager) so tests can use fakes or temp dirs. Runs each probe, merges, then runs the normalizer.
- Probes (`protocol ToolchainProbe`), one file each, grouped by source:
  - `VersionFileProbe`: `.tool-versions`, `mise.toml`, `.nvmrc`, `.node-version`, `.python-version`, `.ruby-version`, `.go-version`, `.java-version`. Highest-precedence version pin.
  - `ManifestProbe`: `package.json` (node via `engines.node`, `packageManager` → pnpm/yarn, devDependencies typescript/eslint/prettier/playwright/cypress/turbo/nx), lockfiles (`pnpm-lock.yaml`, `yarn.lock`), `go.mod` (`go` directive), `Cargo.toml`/`rust-toolchain(.toml)`, `pyproject.toml`/`requirements.txt`/`uv.lock` (python, uv), `Gemfile` (+ `fastlane/`), `pubspec.yaml` (flutter stack), `Package.swift`, `build.gradle(.kts)`/`pom.xml` (java + gradle/maven), `composer.json` (php, composer), `*.csproj`/`global.json` (dotnet), `mix.exs`, `deno.json`, `bun.lockb`, `Dockerfile` (hadolint), `CMakeLists.txt`, `Justfile`/`Taskfile.yml`, `*.tf` (terraform), `Chart.yaml` (helm), `app.json` with expo / `react-native` dep (stacks), `vercel.json`, `wrangler.toml|jsonc`.
  - `WorkflowProbe`: parse `.github/workflows/*.yml` with Yams; map `actions/setup-node|setup-go|setup-python|setup-java|setup-dotnet`, `ruby/setup-ruby`, `dtolnay/rust-toolchain`, `subosito/flutter-action`, `hashicorp/setup-terraform`, `pnpm/action-setup`, etc. (`with: *-version`) and scan `run:` lines for known CLIs (`terraform`, `kubectl`, `helm`, `playwright`, `cypress`, `gh`, `fastlane`, `shellcheck`...). Version from the workflow only fills in when no version-file/manifest pin exists.
- `ToolchainNormalizer.swift`: converts raw hits to catalog specs via `ToolchainCatalog.tool(id:)` / `.stack(id:)` and `ToolchainStack.splitSpec`; drops anything not in the catalog (into `unmatched`, so no `npm:`/`ubi:` specs which `.kinhin.yml` rejects); resolves precedence (version file > manifest > workflow > catalog `defaultSpec`); **adds required runtimes** from each entry's/stack's `requires` (node, java, dotnet); normalizes versions (`^20.1` / `>=20` → `20`, `v22.1.0` → `22.1.0`, `lts/*` → catalog default) and de-dupes (`node@node@22` class of bugs); sorts for stable output.
- Self-check: output goes through `ProjectFileLoader.parse(Data)` (and `ConfigLoader.parseToolchains`) before being returned; a validation failure throws existing `ConfigError`. Detector never returns partial/invalid YAML.
- Error handling: unreadable/invalid project file → `bestEffort`-style logged skip for that probe (via `Log`), not a failure of the whole scan; missing root dir → throw (add a case to `ConfigEditError`/`ConfigError` rather than a new enum). Honors CancellationError.

### CLI: `Sources/kinhin/Commands/ToolchainsDetectCommand.swift`
`kinhin toolchains detect [path] [--json] [--write] [--force]`
- Default path `.`. Prints the `.kinhin.yml` block to stdout and the evidence table to stderr (so stdout stays pipe-able). `--json` prints the Codable result only.
- `--write` writes `<path>/.kinhin.yml` (refuse to overwrite an existing one without `--force`; show a diff-ish notice). 16 KB cap respected.
- Wire it into the `toolchains` branch in `KinhinCLI.swift:58–69` (new `else if`), add a line to `HelpText.swift`, and exempt it from `shouldAutoCreateConfig` since it needs no config. Failures via `fail(error)`.

### Docs
- `docs/toolchains.md`: new "Generating toolchains" section (usage, what is detected, precedence, limitations: only catalog tools, GitHub Actions workflows only).
- `README.md` toolchains section: one-line mention; `website/guide/config.md` only if it duplicates the CLI list. No new page, so no sidebar change.

## Tests (mirror source folders)
- `Tests/KinhinKitTests/Images/ProjectDetection/`: `VersionFileProbeTests`, `ManifestProbeTests`, `WorkflowProbeTests`, `ToolchainNormalizerTests`, `ProjectToolchainDetectorTests` (temp-dir fixtures per CLAUDE.md pattern: node+pnpm+TS repo, Go repo, Flutter repo, Gradle/Kotlin repo adds `java`, workflow-only repo, conflicting pins, unknown tool → `unmatched`).
- Invariant test: every spec the detector can emit for every probe is a catalog entry and passes `ProjectFileLoader.parse`.
- `Tests/KinhinCLITests/`: routing assertion in `CLICommandTests` if needed, plus `ToolchainsDetectCommandTests` (`--json` parseable, `--write` refuses overwrite without `--force`, stdout/stderr split).

## Verification
1. `swift build` and `swift test` (filter to the new suites first, then full).
2. `swift format lint --strict -r Sources Tests`.
3. Manual: run `swift run kinhin toolchains detect .` against kinhin itself (expect `swift`) and against a few sample checkouts (a node/pnpm repo, a Go repo, a Flutter repo); confirm the output round-trips through `swift run kinhin config validate` when pasted as a `projects:` entry and loads via `ProjectFileLoader`.
4. `--write` into a temp dir, then rerun without `--force` to confirm the refusal.

## Notes / risks
- Repo is mid-refactor (many uncommitted changes, `ToolchainsConfigEditor.swift` deleted). The detector is additive and only depends on `ToolchainCatalog`, `ProjectFileLoader` and `ConfigLoader.parseToolchains`, so it should not conflict; implement in its own commit.
- Out of scope for now: remote repos (`--project owner/name`), app UI button, GitLab/Gitea CI files, and writing `projects:` entries into config.yaml (no editor exists after the refactor).
