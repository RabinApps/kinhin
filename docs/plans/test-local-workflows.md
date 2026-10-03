# Plan: Test a GitHub Actions workflow locally

**Goal:** run a repo's workflow YAML on your Mac before pushing it to the forge — from a new CLI command (`kinhin workflow test`, run inside the repo) and from the app (a sheet where you pick the YAML in Finder). Both share one new engine in `KinhinKit`. Host execution only (no VM, daemon, config, or token needed), GitHub Actions format only — per your choices.

## 1. Engine — new domain `Sources/KinhinKit/Workflow/`

Four files, one type per file, mirroring the existing domain layout:

**`WorkflowDocument.swift`** — parse a GitHub Actions workflow with Yams into typed structs:

- `WorkflowDocument { name, path, jobs: [WorkflowJob] }`; `WorkflowJob { id, name, needs, env, defaults, timeoutMinutes, continueOnError, hasMatrix, steps }`; `WorkflowStep { name, uses, run, with, workingDirectory, shell, env, id, continueOnError, condition }`.
- Parsing rules: job `name:` falls back to its key; step name falls back to GitHub's rendering (`Run <first line of run>` / the `uses` ref); `if:` kept as a raw string for the evaluator.
- `locate(in: URL)` discovery: `.github/workflows/*.{yml,yaml}` in the given directory (used by the CLI's default file argument).
- **`WorkflowError.swift`** — one enum for the domain (`unreadable`, `invalidYAML`, `noJobs`, `noWorkflowFound(dir)`, `ambiguousWorkflow([String])`, `unknownJob`, `cyclicNeeds`, `unsupportedShell`) with user-readable `errorDescription`, conforming to `LocalizedError` + `CategorizedError` → `.config` (fix-the-YAML remediation), so the CLI exits 3 on parse problems via the existing `CLIExit` classification.

**`LocalWorkflowRunner.swift`** — `run(document:jobs:workingDirectory:onEvent:) async throws -> LocalRunReport`:

- Jobs run sequentially in `needs`-topological order (`--job NAME` runs one, with a notice that its `needs:` were not run); a `needs` cycle is a `WorkflowError`. Matrix jobs are **skipped** with an explanatory notice (v1).
- Steps run in order via the injected `ShellRunning`: script through stdin as `bash -e -s` (the same pattern `SSHExecutor` uses), `cwd` = working directory; `shell:` overrides map to `bash`/`sh`/`zsh`, anything else → `unsupportedShell`. No change to the `ShellRunning` protocol.
- Environment: CI-style baseline (`CI=true`, `GITHUB_ACTIONS=true`, `GITHUB_WORKSPACE`, `RUNNER_OS=macOS`, `RUNNER_ARCH=arm64`) + workflow → job → step `env:`, injected by prepending `export` lines to the script (values single-quote-escaped). `GITHUB_ENV`/`GITHUB_PATH` get real temp files, and plain `KEY=VALUE` lines a step writes are applied to later steps (documented; heredoc form falls back to a warning). `defaults.run.working-directory/shell` honored; step `working-directory` resolves against the repo root.
- Expressions (minimal, documented): `${{ github.workspace }}`, `${{ runner.os }}`, `${{ runner.arch }}`, `${{ env.NAME }}`, `${{ secrets.NAME }}` (→ empty + one-time warning). Unknown expressions are left literal with a warning in the step log.
- `if:` evaluation: literal `true`/`false` and `success()`/`always()`/`failure()`/`cancelled()`; anything else → step skipped with a note. Failure semantics follow GitHub: a failing step fails the job unless `continue-on-error`; later steps skip unless `if: always()/failure()`; remaining jobs skip after a failure.
- `uses:` steps: `actions/checkout` → no-op success ("working tree already present"); any other action → skipped with a notice (v1 limit, documented).
- `timeout-minutes` per step/job → the `Shell` timeout (default 30 min/step). Cancellation: the caller's task cancel terminates the running child (Shell already handles this), the runner marks the step cancelled and rethrows `CancellationError`.
- `onEvent` callbacks (Sendable enum: job/step state changes + notices) drive the CLI's streamed output and the app's live view.

**`LocalRunReport.swift`** — `Codable` result: `LocalRunReport { workflowPath, workflowName, workingDirectory, startedAt, finishedAt, jobs: [LocalJobResult] }`, jobs → steps with `PipelineStepState` (reused from Forges for display symmetry), timestamps, bounded output text (reuse internal `PipelineLogText`), and per-item notices. Aggregate helpers for final state.

## 2. CLI — `Sources/kinhin/Commands/WorkflowTestCommand.swift`

- Routing: `case workflow` in `CLICommand` (head `workflow`); dispatch in `KinhinCLI` sends `workflow test <args>` to the command; unknown `workflow` subcommand → usage error (exit 2) listing `test`.
- `shouldAutoCreateConfig` returns `false` for `workflow` (like `toolchains detect` — it only reads a repo).
- Usage: `kinhin workflow test [FILE] [--job NAME] [--list] [--json]`. Default FILE = `locate(in: cwd)`; 0 matches → "no workflow found", >1 → list them and ask for one. `--list` prints jobs (id, name, step count, matrix flag) and exits. `--json` suppresses streaming and prints the report JSON (still exit 1 if it failed).
- Streaming output to stdout/stderr per the CLI conventions: `▸ job`, `  ▸ step … ✓ 12.3s / ✗ 45.0s` with each step's output after it finishes; summary at the end. Exit 0 when all jobs pass, 1 when a job fails, 3 for workflow parse errors, 130 for Ctrl-C (all through existing paths).
- `HelpText.swift`: new RUNNING-section entry; then `scripts/docs-sync.sh` regenerates the `kinhin help` block in `website/cli/commands.md` (never hand-edit between markers).

## 3. App — "Test Workflow…" sheet

- New `Sources/kinhin-app/UI/SwiftUI/WorkflowTest/`:
  - **`WorkflowTestModel.swift`** (`@MainActor @Observable`): injected `chooseFile` closure (default: `NSOpenPanel`, `.yml`/`.yaml`, sheet-modal on the window), parse → job list, `start()` runs `LocalWorkflowRunner` in a `Task` and hops events to the main actor (mirrors PipelineModel's shape), `cancel()`, live step states + per-step output, final report.
  - **`WorkflowTestView.swift`**: ~600×520 sheet like PipelineView. Pre-run: "Choose Workflow File…" (Finder), file path + workflow name, job picker (working directory = repo root found by walking up to `.git`, else the file's folder), Run button. Running/finished: step rows with the existing `StateGlyph` + live timing, click a step → output pane (same pattern as PipelineView), Cancel while running, summary banner + "Run again".
- Wiring: `MainSheet.workflowTest` case (+ `present` case), `WindowModels.makeWorkflowTestModel()`, `MainTabsView` sheet rendering, `FleetModel.onShowWorkflowTest`, and a **"Test Workflow…"** button in the Fleet tab's bottom row next to Logs…/Diagnostics…. Stays gated behind first-run setup like every other sheet. Parse errors surface via `AlertKit.present(error:)`.

## 4. Tests

- `Tests/KinhinKitTests/Workflow/` (mirroring the source folder, one class per file): `WorkflowDocumentTests` (parsing fixtures: happy path, env/defaults/working-directory, matrix detection, `if:`/`continue-on-error`, invalid YAML, no jobs, discovery/ambiguity), `LocalWorkflowRunnerTests` against `FakeShell` from `KinhinTestSupport` (call order, script/env preamble via the recorded stdin, cwd, failure→skip semantics, `continue-on-error`, uses/checkout handling, `GITHUB_ENV` application, cancellation, report/JSON shape), `WorkflowErrorTests` (categories).
- `Tests/KinhinCLITests`: `WorkflowTestCommandTests` (list/JSON rendering, job selection, exit codes, default-file discovery with temp dirs) + updates to the routing-table, help-text, and auto-create-policy tests.
- `Tests/KinhinAppTests`: `WorkflowTestModelTests` (injected file chooser + fake shell: run → progress → finish, cancel, parse error) and updates to sheet/navigation tests for the new `MainSheet` case and Fleet-tab button.

## 5. Docs

- New `docs/workflow-testing.md` guide (what runs on your Mac, what is skipped: matrix/actions/secrets, exit codes, examples, app flow) + sidebar entry under "Run your fleet" in `website/.vitepress/config.ts`.
- README: row in the Commands section.
- `CHANGELOG.md`: Unreleased entry.
- Regenerate the help block: `bash scripts/docs-sync.sh` after editing `helpText()`.

## 6. Verification

`swift build`, `swift test`, `swift format lint --strict -r Sources Tests`, `bash scripts/docs-lint.sh`, `bash scripts/docs-sync.sh --check`, `cd website && npx vitepress build`. TSan not required (no new shared state — the runner is plain async, the model is `@MainActor`); will run if the implementation ends up adding locks.

## Out of scope (deliberate v1 cuts)

VM/container execution mode, matrix expansion, real action support (`uses:` beyond checkout), other forges' YAML formats, live per-character output streaming (Shell accumulates per step today; events fire on step boundaries).
