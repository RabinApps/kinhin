# Automated benchmarks: `kinhin bench` (CLI) + Advanced → Benchmarks (app)

A self-contained benchmark harness that measures, on this Mac, how fast every runtime boots, how fast representative workloads run inside them, and how fast every toolchain in the catalog installs and builds, writes a machine-readable report, and cleans up everything it created.

## 1. New `KinhinKit/Benchmarks/` domain (new error enum `BenchmarkError`)

- **`BenchmarkReport.swift`** — `Codable` report: run id, start/end, kinhin version, host snapshot (chip, cores, RAM, free disk via existing `ResourceProbe`/`HostResources`), config snapshot (image, runtimes, VM shape), intensity, and per-suite results. Each suite → `{ name, runtime, platform?, status: ran|skipped|failed, skipReason?, steps: [{ name, durationMs, throughput? (bytes/s), note? }] }` — every suite names the runtime (and guest platform) it measured, so runs compare across runtimes; the toolchains suite instead carries one flat step per catalog entry: `{ tool, platform, runtime, installer, status: ran|skipped|failed, installMs?, verifyMs?, workloadMs?, workload?, skipReason?, note? }`. Written to `~/Library/Application Support/Kinhin/bench/results-<timestamp>.json`.
- **`BenchmarkRunner.swift`** — orchestration only, no forge/`FleetEngine` dependency, and **no token/Keychain access at all** (registration is skipped, so no credentials ever reach a bench VM or a report). Preflight (per selected runtime: its `health()` probe and its image available — in `tart list` or pulled locally — else "run `kinhin image prepare` first"; free-disk check, hard payload-size caps), fleet pause/drain/resume (below), scratch setup, suite execution, report write, guaranteed cleanup in a `defer`/`bestEffort` so a failed or cancelled run still deletes its VMs and scratch.
- **`BenchmarkScratch.swift`** — generates payloads (Swift package sources, file trees, byte blobs) into a per-run host scratch dir (0700, files 0600, via `Paths.createPrivateDirectory`/`writePrivateFile`) and provides the removal.

## 2. The five suites

- **Boot** (every runtime whose prerequisites are healthy on this Mac, configured or not — probed through the existing `Runtime.health()`; `--runtime tart|appleContainer|docker|host|all` overrides): one result per runtime, so the report answers "which runtime boots fastest on this Mac". Tart: for each iteration, clone `kinhin-bench-<run>-<n>` from the image → time phases exactly like `FleetLifecycle` does: `clone`, `boot-to-IP` (`tart ip --wait` loop), `IP-to-SSH-ready` (TCP-22 probe + host-key pinning + one trivial SSH exec); then one **warm boot** measurement (stop → start → SSH-ready); min/median/max per phase. Apple-container and Docker: ensure image → `create` → `start` → `exec-ready` (first exec exits 0); Docker optionally adds an **amd64 pass** under its configured emulation — the documented speed trap — as a separate result. Host: no clone/boot — `spawn` (agent install into a scrubbed scratch work dir) → `ready` (one trivial exec), tagged `unisolated`, only with explicit `--include-host` consent like host routes.
- **Casual** (one shared bench VM): per-SSH-exec overhead loop, file I/O (create ~256 MB tree, tar+gzip, unzip, `shasum`), `git init` + commit of hundreds of generated files, and a `swift build` of a small generated package (skipped with a note if the image has no Swift toolchain).
- **Xcode**: probe `xcodebuild -version` in-guest; absent → `skipped` ("bake Xcode into the image"). Present: generate a multi-hundred-file Swift package, time `xcodebuild build` (clean + incremental). `--project <path>` **copies** a real checkout into the guest scratch (tar over SSH, `tar -C src .` so extraction can't escape via absolute paths) and builds it there — the realistic "large workflow" mode.
- **Large**: disk throughput (write/read/checksum a multi-GB blob → MB/s), multi-core CPU throughput (parallel gzip), and — only with `--network <url>` — a timed real `git clone` (shallow) inside the disposable VM. Default fully offline/deterministic.

`--quick` (default: 1 boot iteration, small payloads, ~5–10 min) vs `--thorough` (3 iterations, 2–4 GB payloads); for toolchains, quick = verify + workload only (minutes), thorough = the full cold-install pass for every entry (hours — `--toolchains node,go,…` / `--all-toolchains` scope it). UI gets a Quick/Thorough picker. Suite selection: `kinhin bench [boot|casual|xcode|large|toolchains …]`, default all **except toolchains** (it takes hours on purpose — run it when you want the table).

**Toolchains** (opt-in — one row for every `ToolchainCatalog` tool and stack, on each platform the entry claims, via `ToolchainEntry.platforms` and `installer(for:)`): the full speed story per toolchain, timed in a bench instance of the right platform (tart macOS VM for macOS tools, the selected Linux runtime for Linux tools — one instance per platform per run):

- **install** — cold, through the exact `image prepare` path: resolve with `ToolchainCatalog.selection(from:platform:)`, generate the single-tool managed-toolchain install script, run it with the shared cache mount **disabled** — the number a fresh image pays. Thorough tart passes clone one fresh VM per tool **category** (the `ToolchainCategory` groups), not per tool; container runtimes get a fresh container per tool (cheap).
- **verify** — the entry's `verify` command; nonzero exit fails the step, so the report doubles as an install-correctness check.
- **workload** — a tiny generated, fully offline build/run per tool family: `go build` a package, `cargo build` a hello crate, `node`/`deno`/`bun` run a script, `javac`+`java`, `dotnet new`+`build`, `swift build` of the casual suite's small package, `tsc`/`eslint` on one file, `cmake` configure+build of a one-file project, `terraform validate` / `helm template` on generated files, … No meaningful offline workload (playwright, cypress, fastlane, netlify-cli, k9s, pulumi, vault, …) → the step reports `skipped` with a reason, verify-only. Entries already baked into the image carry `note: "preinstalled"`; stacks (flutter) expand to their resolved pieces like a bake does; cloud CLIs never touch live services.

## 3. Data created and removed (explicit lifecycle)

**Created, then removed after the run (also on failure/cancel):**

- tart VMs named `kinhin-bench-*` (clones of the configured image) and equivalent bench containers — stopped + deleted via `TartControlling.stop/delete` / container rm, with `ssh.forgetHostKey(vm:)` so no stale known-hosts pins linger.
- In-guest scratch: a `kinhin-bench/` directory with scripts, payloads and the toolchains suite's generated workloads (toolchain installs themselves land in the instance's normal toolchain locations and are discarded with it) — `rm -rf`'d before teardown (belt-and-braces; VM deletion discards it anyway).
- Host scratch: `~/Library/Application Support/Kinhin/bench/<run-id>/` holding generated package sources and payload blobs — removed whole unless `--keep` (debugging). Never touches the config file, Keychain, toolchain cache, or the base image.

**Kept:** the per-run `results-*.json` reports — no credentials, host-local under a 0700 directory (history for before/after comparison; pruned to the newest ~20). Cleanup is idempotent and safe to re-run; stray `kinhin-bench-*` VMs from a crashed run are swept up by the next run's preflight and by `kinhin cleanup` (its `kinhin-` prefix already matches).

## 4. Fleet interaction (confirm → auto-pause → resume)

Preflight: if the fleet has active VMs, CLI asks for confirmation (auto-yes with `--yes`; non-interactive scripts must pass it), then `engine.setPaused(true)`, waits (bounded) for busy VMs to drain — `--force` skips the wait — runs, and **resumes in a defer** so resume happens even on failure. App: confirm dialog, then same sequence through the daemon.

## 5. RPC + daemon (updates the docs-sync `rpc-methods` table)

- `bench_start` (payload: suites, intensity, options → returns run id immediately) and `bench_status` (run id → current suite/step, elapsed, partials, last completed report). Needed because `RPCServer.handlerTimeout` is 120 s and a run takes minutes: the daemon starts the benchmark as a detached task; the app polls `bench_status` every ~2 s. `bench_start` is `mutatesFleet` (serialized through the engine gate). `RPCMethod` + `RPCClient` helpers + `FleetServing`/`FleetBackend` bench methods (inProcess backend calls `BenchmarkRunner` directly). The new methods ride the existing socket security: 0600 socket, 0700 directory, per-peer-uid check — no new auth surface.

## 6. CLI (`Sources/kinhin/Commands/BenchCommand.swift`)

Routing case `.bench` in `CLICommand`; help entry under RUNNING in `helpText()` (then `scripts/docs-sync.sh` regenerates `website/cli/commands.md`). Flags: suites, `--quick|--thorough`, `--iterations`, `--runtime`, `--toolchains <id,…>` / `--all-toolchains` (toolchains suite selection), `--include-host` (host boot consent), `--network <url>`, `--project <path>`, `--yes`, `--json` (DoctorCommand-style machine output, stdout only), `--keep`. Errors exit through the standard `fail(_:exit:)` classification (`BenchmarkError` → exit 4).

## 7. App UI — Advanced → Benchmarks

`AdvancedSection.benchmarks` (+ label, sidebar order), `WindowModels.ensureSection` → **`BenchmarksModel`** (`@MainActor @Observable`: suite toggles — including Toolchains, off by default —, intensity picker, Run → confirm dialog → start, poll loop, progress line, results table, history list) and **`BenchmarksView`** (SwiftUI section view, plus a small summary card on the Fleet tab linking to it). Results render two shapes: the boot comparison across runtimes (per-runtime phase columns) and the toolchains table (one row per catalog entry — install/verify/workload times, sortable, skip reasons inline). Wired through `MainTabsModel.refreshVisibleTab`; `AlertKit.present(error:)` for failures.

## 8. Security notes

- **No secrets in play.** Bench never reads the Keychain, mints registration tokens, or runs forge registration; reports and logs contain no credentials. `LogRedactor` still guards anything that flows through `Log`.
- **Guest access reuses the runner path.** Same guest SSH key trusted by `image prepare`, same per-VM host-key pinning (`GuestHostKeyPinning`) before the first SSH, same image-side SSH hardening (password login disabled); teardown calls `forgetHostKey`. No new auth mechanism is introduced.
- **Network isolation preserved.** Bench boots VMs with the configured `tart_softnet` setting, so isolated fleets benchmark isolated VMs (the existing `TartController.runEnvironment` PATH fix applies).
- **Untrusted input is bounded.** `--project` trees are copied into guest scratch (never mounted read-write from the VM's perspective) with symlink-safe `tar -C src .` extraction; `--network` accepts only git URL schemes; generated shell scripts interpolate paths/URLs with explicit quoting and nothing is ever piped from the network into a shell. Clones execute inside the disposable VM, not on the host.
- **Toolchain workloads are offline by construction.** Generated sources only; cloud CLIs run version/validate flags, never live services; no step needs or reads credentials, so a toolchain bench can't exfiltrate anything.
- **Host-mode bench is consent-gated.** `--include-host` mirrors host routes' consent rule; host payloads run only in a scrubbed scratch work dir.
- **Resource limits.** Hard caps on payload/iteration sizes regardless of flags, preflight free-disk check (the existing pre-spawn disk-guard pattern), timeouts on every SSH/shell exec, and cancellation tears everything down — a hung VM can't wedge the daemon.
- **Permissions.** Host scratch is 0700 with 0600 files (atomic `writePrivateFile`), results live inside the already-private app-support tree; no elevation or root anywhere.

## 9. Tests + docs

- `Tests/KinhinKitTests/Benchmarks/` against `FakeTart`/`FakeSSH`/`FakeShell` (from `KinhinTestSupport`): phase timings captured, pause/resume called, cleanup verified on success _and_ failure, skipped-suite logic, report round-trip, URL-scheme and payload-cap validation. `KinhinCLITests`: routing, flags, `--json` contract, help. `KinhinAppTests`: model transitions/polling/confirm flow against a fake backend. RPC handler tests for start/status.
- **Coverage invariants — the "every runtime and toolchain" guarantee:** one test walks `RuntimeID.allCases` and fails when a runtime has no boot phases/report row (adding a runtime without bench coverage breaks CI); a sibling of `ToolchainCatalogInvariantTests` walks every `ToolchainCatalog` tool and stack on each claimed platform and fails unless it yields a bench plan — installer resolved via `installer(for:)`, its `verify` included, and either a workload or an explicit skip reason.
- Toolchain-suite behavior: generated install scripts carry no cache-mount envs (cold), quick vs thorough gating, preinstalled/skip notes, workloads built from generated sources only (nothing fetched), per-category tart clones in thorough mode.
- New `docs/benchmarks.md` (what each suite measures, data lifecycle, flags, security notes, reading the numbers) added to the website sidebar; `bash scripts/docs-lint.sh` + `docs-sync.sh` + `cd website && npx vitepress build`.
- Verification: `swift build`, `swift test`, `swift format lint --strict -r Sources Tests`; `scripts/tsan.sh` since the runner is an actor with detached daemon tasks.

File sizes stay under the ~400-line smell by splitting suites into `BootBenchmark.swift` / `WorkflowBenchmark.swift` / `ToolchainBenchmark.swift` etc.

## Implementation notes

What shipped differs from the plan above in these places:

- **`bench_cancel`.** A third RPC method, `bench_cancel`, lets Ctrl-C in the CLI and the app's Cancel button stop a run
  that lives in the daemon; without it a cancelled client would leave a multi-hour run going unattended.
- **Container boot phases** are `start` (create + start, one `run --detach`) and `exec-ready`; Docker's `linux/amd64`
  emulation pass runs in thorough mode when an amd64 image of the configured name is on the Mac, and reads `skipped`
  otherwise.
- **`--force`** is a flag of its own (skip the wait for busy VMs); `--yes` only agrees to the fleet pause.
- **Exit code 1** also covers a toolchain row that failed to install, verify or build, so a thorough run doubles as
  an install-correctness gate.
- **Thorough toolchains** requires `--toolchains` or `--all-toolchains` (tens of minutes over the whole catalog); a quick pass is unscoped by
  default.

