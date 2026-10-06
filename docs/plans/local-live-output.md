# Local live job-output tap for the pipeline view (all runners)

**Goal:** show a running job's output from _inside kinhin's own runner instance_ — no forge-API log calls while a job runs — through one shared interface that all six agents plug into, with the existing API path kept as fallback.

**Why:** GitHub has no streaming API; today's pipeline sheet re-downloads the whole job log (302 + multi-MB blob) every 2 s and waits ≥60 s for the first blob flush. The runner already writes the _byte-identical, secret-masked_ job log to `_diag/pages/…` inside the instance. Five of six agents have an equivalent local source; GitLab's lives in its trace API instead.

## Design: one interface, two source families, one transport

1. **Transport — reuse what exists.** Every runtime already runs an arbitrary script inside an instance: `ExecutionRuntime.execRegistration` (Tart → SSH, Docker/Apple container → `exec`, host → local `bash -s`; call site pattern: `FleetLifecycle.swift:141`). v1 reads are one-shot `tail -c +N <file>` per refresh tick (the sheet already polls every 2 s), so **no new streaming primitive and no protocol change**; a long-lived `tail -F` is a later optimization.
2. **Tap core — per-agent spec + offset cache** that decodes raw bytes into the existing `PipelineLog` (reusing `PipelineLogText.clean` / `.slice` / `.limit`).
3. **Fallback rule — local first, API second.** `FleetEngine.pipelineLog` tries the tap; any miss (file gone, no flag, older image, exec error) falls through to today's `forge.pipelineLog`. `pipelineDetail` (states/steps) stays on the API with its 2 s cache and free 304s. No RPC, daemon, app, or CLI changes — both the sheet and `kinhin pipeline --follow` inherit it.

### Per-agent matrix

| Agent         | Local source                                                                                                             | Opt-in needed                                                 | Stage |
| ------------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------- | ----- |
| GitHub        | job-level file in `<agentDir>/_diag/pages/*_*.log` (marker: first line `Current runner version`; else largest page file) | none                                                          | 2     |
| Buildkite     | `agent.log` (kinhin already redirects it)                                                                                | `--write-job-logs-to-stdout` in `buildkiteRegistrationScript` | 3+4   |
| Bitbucket     | `runner.log` (console) + rolling `${BASE_LOG_PATH}/runner.log`                                                           | `BITBUCKET_PIPELINES_RUNNER_BUILD_LOG_ENABLED=TRUE`           | 3+4   |
| Azure DevOps  | `_diag/<buildLogs>/<timelineId>/<stepName>-<recordId>.log` (`{O}` timestamps, per step)                                  | `ReStreamLogsToFiles` agent setting (verify writability)      | 3+4   |
| GitLab        | no local file → **API-family adapter**: trace endpoint with `Range: bytes=off-`                                          | —                                                             | 4     |
| Gitea/Forgejo | console carries job output **only at debug level** (risk: echoes variables) → **no tap in v1**, documented gap           | deferred (config opt-in later)                                | —     |

Multi-runner VMs (`run-1..N`, `~/actions-runner-2..N`): map runner name → agent dir by reading each dir's `.runner` (`agentName`), so a job's page file is picked even with several jobs per VM. Works for classic _and_ scale-set/JIT registration (same layout).

## Stages

### 1. Tap core — `Sources/KinhinKit/Forges/Pipeline/`

- **`LocalLogTapSpec.swift`** — per-agent description: agent-dir glob, page/file glob, first-line marker, `durability` (`.vanishesAtJobEnd` GitHub / `.persistent` others), `lineFormat` (`.timestampedTagged` / `.console(prefixStrip:)`), scope (job/step).
- **`LocalLogTapReader.swift`** — builds a POSIX script (no `set -e`): locate dir → pick file (marker, else largest) → print a `KINHIN-SIZE <n>` header line → `tail -c +N`; parse header; **if reported size < offset → file rolled over/recreated → reset offset and re-read**; missing file → sentinel → `nil`. Verify `tail -c +N` against BSD (macOS guest/host), GNU and busybox.
- **`LocalLogTapCache.swift`** — `Mutex<[Key, Int64]>` offsets, bounded ~64 entries with age eviction (mirrors `PipelineDetailCache`); key = (vmID, runnerName, filePath). New shared state → **`scripts/tsan.sh` required**.
- Decode path reuses `PipelineLogText.clean` + `slice(jobLog:steps:index:)` and bounds to `PipelineLogText.limit` (200 k), so local and API output are indistinguishable to the UI.

### 2. GitHub adapter + engine wiring

- **`Sources/KinhinKit/Forges/Github/GitHubLocalLogTap.swift`** — runner-name→dir mapping via `.runner`, job-file selection, offset read, decode. GitHub's page lines carry the same `{O}` timestamps and `##[section]`/`##[group]` markers as the REST blob → existing step slicing works unchanged (markers later allow exact boundaries).
- **`FleetEngine+Pipeline.swift`** — in `pipelineLog(vmID:jobID:stepIndex:)`, resolve runtime/instance exactly like `FleetLifecycle.swift:141` (`record.runtime`, `record.ip`, instance id), try the tap, else `forge.pipelineLog`. Extract a small `execInInstance(record:script:)` helper shared with lifecycle. Keep behavior when the job just ended: file is uploaded-then-deleted → API fallback supplies the canonical final text.
- Never log tap payloads (no `Log.info` of content).

### 3. Bootstrap opt-ins (one line each, independent commit)

- `RunnerBootstrap+Buildkite.swift` (~L74–80): add ` --write-job-logs-to-stdout` to `start`.
- `RunnerBootstrap+Bitbucket.swift` (~L133–144): export `BITBUCKET_PIPELINES_RUNNER_BUILD_LOG_ENABLED=TRUE`.
- `RunnerBootstrap+AzureDevOps.swift` (~L115–124): set `ReStreamLogsToFiles` in the agent settings after `config.sh` (verify the `.agent` field; if not writable, Azure stays API-only).
- Update the script-assertion tests (`AppleContainerRuntimeTests` L127/143, `DockerLifecycleTests` L349/351, plus Buildkite/Bitbucket equivalents).

### 4. Remaining adapters (same interface, one small file each)

- **Buildkite**: parse `agent.log` — strip agent lifecycle lines, keep job output (job-level scope only, matching today's capability).
- **Bitbucket**: parse console/`runner.log` — strip logback `[date]` prefix; build-log lines are tagged per Atlassian's encoder; step boundaries as the format allows, else job-level.
- **Azure**: per-record files = exact per-step output; map `<stepName>-<guid>.log` to steps by order/name.
- **GitLab**: API adapter — offset-cached `Range` request against the trace endpoint (live, stops re-downloading the whole trace).
- Each adapter ships with a `PipelineLogFetchTests`-style case (tests folder is flat: `Tests/KinhinKitTests/Forges/…`).

### 5. Docs + website

- `docs/app.md` pipeline section (per-forge table gains "source while running: local tap / API"), `docs/forges/github.md` (log paragraph: `_diag/pages` primary, REST fallback), buildkite/bitbucket/azuredevops/gitlab/gitea pages, `docs/adding-a-forge.md` (optional tap alongside `pipelineLog`), `docs/architecture.md` map row. Never edit between `docs-sync` markers; finish with `cd website && npx vitepress build`.

## Tests & gates

- New: `LocalLogTapReaderTests` (script shape, size header, rollover reset, missing file, marker selection, truncation), `GitHubLocalLogTapTests` (FakeShell/FakeSSH canned output, `.runner` mapping, multi-runner), engine test: `pipelineLog` prefers tap and falls back on miss, parity test: local vs API produce identical text for the same log.
- Updated: bootstrap script assertions (stage 3).
- During work: `swift format lint --strict -r Sources Tests` + `scripts/check.sh --fast`; finish with full `scripts/check.sh` and `scripts/tsan.sh` (new `Mutex` cache).

## Commit order (behavior vs mechanical kept apart)

1. Tap core + GitHub adapter + engine wiring + tests.
2. Bootstrap opt-ins + their test updates.
3. Buildkite/Bitbucket/Azure/GitLab adapters + tests.
4. Docs + website build.

## Verify while building

`.runner`'s `agentName` key on a real registration; `tail -c +N` semantics on all three `tail` flavors; page-file deletion timing at job end (fallback seam); Azure `.agent` setting writability; real console formats for Buildkite/Bitbucket (captured samples → parser tests); Gitea deferred (debug-level job output can echo secrets).

**Non-goals:** long-lived `tail -F` streams (v2 if per-tick SSH proves heavy), Windows guests, keeping logs after job end, any webhook/SSE work, UI changes (the existing "live" mark just starts reflecting local freshness).
