# Opt-in GitHub Runner Scale Set mode (actions/scaleset-style, in Swift)

## Goal

Add a **second demand mode** for GitHub accounts in kinhin: instead of polling the REST workflow-runs API, the engine runs GitHub's **Runner Scale Set message API** (the same API the Go `actions/scaleset` client wraps) — long-polled job messages, JIT runner configs, statistics-driven autoscaling. **Opt-in per account** via a config key; the classic poller stays the default and unchanged.

## Design (from your answers)

- **PAT only** in v1 — reuses kinhin's existing Keychain PAT and the registration-token call it already makes. GitHub App auth is a follow-up.
- **Scope**: config + engine + docs. `AccountsConfigEditor` learns to round-trip the new key (it rewrites the `accounts:` block, so this is required to not clobber it); no new app UI form.
- **Per-pool scale sets, engine-owned listener** (your question): GitHub matches jobs to a scale set by labels and hands a job to _any idle runner in it_, so one scale set per account would break kinhin's routing. Instead:
  - The scale-set **client** (API plumbing) lives in `Forges/`; the **listener/session machinery** (message loop, demand snapshot) lives in `Fleet/` as an engine-level component, like `reconcileLoop`.
  - The engine creates **one scale set per (account, runtime pool)**: `kinhin` (tart/default), `kinhin-container`, `kinhin-docker`, … each with that pool's labels. Spawn-time VM targeting (repo/workflow/label routing, image routing) stays 100% kinhin's. Single-pool fleets — the common case — get exactly one scale set and one session.

## API chain (verified against actions/scaleset sources)

1. **Admin connection**: `POST /orgs|/repos/{scope}/actions/runners/registration-token` (existing `GitHubClient`) → `POST https://api.github.com/actions/runner-registration` with `Authorization: RemoteAuth <regToken>` and body `{url: "https://github.com/<scope>", runner_event: "register"}` → `{url: <Actions-service URL>, token: <JWT>}`. JWT refreshed when <60 s from expiry (re-run both steps).
2. **Ensure scale set** (api-version=6.0-preview, Bearer admin JWT): `GET _apis/runtime/runnergroups/?groupName=<group>` → `GET _apis/runtime/runnerscalesets?runnerGroupId=<id>&name=<name>` (create via `POST` when missing, labels = pool labels; `PATCH` when config labels change; scale-set name doubles as a `runs-on:` label).
3. **Message session**: `POST _apis/runtime/runnerscalesets/{id}/sessions` `{ownerName: "kinhin"}` → `{sessionId, messageQueueUrl, messageQueueAccessToken}`. Poll `GET <messageQueueUrl>?lastMessageId=<n>` with `X-ScaleSetMaxCapacity` header → **200** batch or **202** empty. Ack with `DELETE <messageQueueUrl>/<messageId>`. On 401: `PATCH _apis/runtime/runnerscalesets/{id}/sessions/{sessionId}` to refresh. `DELETE .../sessions/{sessionId}` on engine stop.
4. **Scale on `statistics.TotalAssignedJobs`** (never message counts). `JobAvailable/JobAssigned/JobStarted/JobCompleted` bodies carry `ownerName`, `repositoryName`, `jobDisplayName`, `requestLabels`, `runnerRequestId` → per-pool demand, per-repo attribution, image routing, busy marking.
5. **Runner provisioning**: spawn VM exactly as today; at the registering phase `POST _apis/runtime/runnerscalesets/{id}/generatejitconfig` `{name: "kinhin-…[-rN]", workFolder: "_work"}` → `encodedJITConfig`; the in-VM bootstrap registers with `./config.sh --jitconfig '<config>' --unattended --replace --work _work` (no `--url/--token/--labels/--name` — scale-set runners are one-job ephemeral by design).
6. **Exit watch unchanged**: scale-set runners appear in the existing REST runners list; disappearance = job done → delete VM (fallback if GitHub lingers: `GET _apis/distributedtask/pools/0/agents?agentName=` on the Actions service).

## Config (opt-in)

```yaml
accounts:
  - name: github
    forge: github
    scope: your-org # org or owner/name — both supported
    scale_set: # ABSENT → classic poller (today's behavior, default)
      name: kinhin # scale-set name base (per-pool suffixes derived)
      # runner_group: default
```

Validation: `scale_set` requires `vm.ephemeral: true` (scale-set runners deregister after one job — persistent VMs are contradictory); name must be a valid label; per-pool derived names validated the same way.

## Changes

**New files**

- `Forges/GitHubScaleSetModels.swift` — Codable DTOs (scale set, statistics, session, messages, JIT config) with explicit `CodingKeys`.
- `Forges/GitHubScaleSetClient.swift` — admin-token exchange + refresh, scale-set ensure/patch, session create/refresh/delete, `getMessage`/`deleteMessage`/`acquireJobs`, `generateJitConfig`, agents lookup. Built on `ForgeHTTP` with an injectable session (matches `GitHubClient`, testable via `StubProtocol`). New cases on `GitHubError`, user-readable messages (401 on runner-registration → PAT guidance).
- `Fleet/ScaleSetListener.swift` — actor owning one session: ensure scale set → poll loop → update a `Mutex`-guarded snapshot (statistics, tracked pending jobs, repo attribution) → `engine.pollSoon()` on every message; backoff + session recreate on repeated failures; `maxCapacity` = `Autoscaler.jobCapacity(...)` refreshed per poll.

**Modified**

- `Forges/Forge.swift` — `ForgeRegistration` gains `.jitConfig`; `Forge` gains `jitRunnerConfig(name:labels:) async throws -> String` (default `unimplemented`-style guard; only jitConfig forges implement it).
- `Forges/GitHubScaleSetForge.swift` — the `Forge` adapter: `queuedJobs()` served from the listener snapshot (synthesizing placeholder jobs when tracked < `TotalAssignedJobs` so counts always meet statistics; per-pool routing via the existing `RuntimeRouter`), `runners()`/`deleteRunner()`/`pipelineDetail`/`pipelineLog`/`projectFile` delegated to the existing REST `GitHubClient` unchanged, `registration = .jitConfig`.
- `Fleet/FleetLifecycle.swift` — credentials switch gains the `.jitConfig` case (calls `forge.jitRunnerConfig`, passes it to the script).
- `Images/RunnerBootstrap/RunnerBootstrap.swift` (+ Linux flavor) — `jitconfig` registration-script variant (`--jitconfig`, no URL/labels/name; JIT config is secret-treated like tokens today: never logged, `LogRedactor` pattern for it).
- `Fleet/FleetEngine+Accounts.swift` — `attach(account:)` builds a `GitHubScaleSetForge` when `account.scaleSet != nil`; `launch()` starts one listener per pool scale set; `stop()` cancels listeners and deletes sessions (best-effort).
- `Config/AccountConfig.swift` — `scaleSet: ScaleSetConfig?` (`name`, `runnerGroup`) with `snake_case` CodingKeys; validation in the loader sections; `ConfigTemplate.swift` commented example; `AccountsConfigEditor.sectionText` serializes the key (so edits never drop it).
- `Fleet/FleetStatus.swift` — optional `scaleSetName` (+ "event-driven" hint) surfaced in the status line / `kinhin status --json`.

**Docs** (edited in place, no new pages → no sidebar changes)

- `docs/scaling.md`: new "Scale set mode (opt-in)" section — when to prefer it (event-driven pickup, no poll_interval latency, no REST reads against the rate-limit budget), the config key, what changes (`runs-on:` may target the scale-set name), limits.
- `docs/forges/github.md`: API notes for the scale-set endpoints and PAT requirements.
- `docs/architecture.md`: one line in the source-layout table for the new Fleet/Forges files.

## Behavior notes

- Pause/auto-resume, idle handling, min/max runners, `runners_per_vm` density (N JIT configs per VM), budget/capacity caps, disk-pressure holds, recovery-on-restart: all unchanged — the listener only replaces _where demand comes from_.
- Long polls don't hit api.github.com, so the rate-limit slowdown mostly disappears in this mode; `poll_interval` still paces reconcile passes (scale-down, retries).
- Messages are acked only after processing; redelivery is tolerated (idempotent handling); engine restart creates a fresh session (GitHub GCs orphaned sessions).

## Tests (mirror existing layout, fakes only — no network)

- `Tests/KinhinKitTests/Forges/`: client over stubbed URLProtocol — registration exchange, refresh-on-expiry, ensure/patch scale set, session create/401-refresh/delete, 200/202 message parse, ack, JIT config.
- `Tests/KinhinKitTests/Fleet/`: listener (statistics-driven demand, redelivery, capacity header, restart), forge adapter (`queuedJobs` meets statistics, routing conversion), engine integration using the existing fake-forge harness (message → spawn → jitconfig register → exit → delete).
- Bootstrap script assertions (macOS + Linux flavors), config parsing/validation/editor round-trip (editor must not drop the key).
- Gates per CONTRIBUTING: `swift build`, `swift test`, `swift format lint --strict -r Sources Tests`, `scripts/tsan.sh` (new actor + `Mutex` shared state), docs lint/sync + `vitepress build`.

## Non-goals (explicit follow-ups)

GitHub App credentials; GHES instance support; a Fleet-tab scale-set card / account-form toggle; deleting scale sets on teardown (left in place — cheap and re-attached); porting the same mode to GitLab/Buildkite.
