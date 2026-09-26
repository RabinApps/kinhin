# Runtime Abstraction — Design Document

**Status:** Approved design · **Prerequisite:** Forge abstraction (shipped) · **Composes with:** Forge (a job is a _(forge, repo, runtime)_ triple)

---

## 1. Problem

kinhin currently hardwires one execution runtime: every runner is a Tart macOS VM. That costs a
Tart dependency for users whose workloads are Linux-only, prevents cheaper execution for Linux
jobs, and offers no story for trusted repos that want a warm, non-isolated runner. The Forge
abstraction solved _who hands us jobs_; this layer solves _where jobs execute_ — with per-repo
routing so one fleet can mix runtimes across repositories.

## 2. Non-goals

- **Running macOS jobs without Tart.** No container or host backend can execute macOS workloads
  on a Mac; Tart remains the only macOS runtime. The abstraction makes Tart _optional for the
  product_ (Linux-only users never install it) — not optional for macOS jobs.
- Replacing the Forge abstraction. Runtime and Forge are orthogonal axes and compose: a job is
  a (forge, repo, runtime) triple.
- Multi-node fleets: everything here is one-host, as today.

## 3. Core model

A job is served by a **(forge, repo, runtime)** triple. The runtime axis:

```swift
public enum RuntimeID: String, Codable, Sendable {
    case tart      // macOS VMs (macOS jobs only)
    case docker    // Linux containers inside one shared Linux VM (Linux jobs)
    case host      // direct execution on the host Mac (trusted repos, opt-in)
}
```

### 3.1 The Runtime protocol

Mirrors the lifecycle seams the engine already has (clone → boot → register → watch → delete),
so adoption is a refactor rather than a rewrite:

```swift
public protocol Runtime: Sendable {
    var id: RuntimeID { get }
    /// Prerequisite probe for the checklist/doctor (hermetic via injection).
    func health() async -> RuntimeHealth
    /// True when this runtime can serve the given repo's jobs.
    func canServe(repo: String) -> Bool

    // Lifecycle — one call per engine lifecycle seam.
    func provision(id: String, route: RepoRoute) async throws
    func registrationScript(route: RepoRoute, token: String, name: String,
                            runnerCount: Int) async throws -> String
    func watch(id: String, route: RepoRoute, runnerCount: Int) async throws   // ephemeral exit
    func teardown(id: String, route: RepoRoute) async                         // idempotent

    // Warm runners (host runtime only; VM runtimes register inside provision).
    func registerWarmRunner(route: RepoRoute, name: String) async throws
    func deregisterWarmRunner(name: String) async throws
}
```

`RuntimeHealth`: `.ready`, `.missing(tool: String, fix: String)`, `.broken(String)` — the same
shape as `TartHealth` today, so the checklist renders it with existing machinery.

### 3.2 The three implementations

|                         | `TartRuntime`                                | `DockerRuntime`                                              | `HostRuntime`                           |
| ----------------------- | -------------------------------------------- | ------------------------------------------------------------ | --------------------------------------- |
| **OS**                  | macOS                                        | Linux (containers)                                           | any (runs on your Mac)                  |
| **Isolation**           | per-job VM                                   | per-job container in one shared Linux VM                     | none — consent-gated                    |
| **Provision**           | clone+boot Tart VM (today's path)            | ensure shared Linux VM up, one container per concurrent slot | nothing                                 |
| **Registration**        | SSH: config.sh / act_runner register (today) | same scripts, exec'd via `docker exec`                       | `registerWarmRunner` on the host itself |
| **Watch**               | `awaitEphemeralExit` (today)                 | container presence + runner status                           | runner-status polling, no deletion      |
| **Teardown**            | stop+delete VM (today)                       | `docker rm -f` (cleaner than VMs)                            | deregister + scrub work dir             |
| **Ephemeral semantics** | fresh VM per job                             | fresh container per job-slot                                 | warm runner, periodic scrub             |

Consequences:

- **Docker on macOS = Linux containers inside one Linux VM** (Docker Desktop/OrbStack/colima).
  kinhin treats that Linux VM as _infrastructure_ (started, monitored, counted in capacity),
  not as a runner. One Linux VM serving N container slots is drastically cheaper than N macOS
  VMs — that is Docker mode's entire value proposition.
- **Host mode is opt-in per repo, with an explicit consent step in the UI** ("this runs repo
  code directly on your Mac, unisolated"). Never a default.

## 4. Per-repo routing config

```yaml
# Which runtime serves which repo. First match wins; `default` catches the rest.
runtimes:
  default: tart
  routes:
    - repo: acme/ios-app # macOS workload → must be tart (validated)
      runtime: tart
    - repo: acme/api # Linux workload on cheap containers
      runtime: docker
      docker:
        image: ghcr.io/acme/ci-linux:latest # container image for its job slots
        max_slots: 4
    - repo: acme/scripts # trusted internal scripts, warm host runner
      runtime: host
      host:
        labels: [kinhin-host, trusted]
```

Parse/validation rules (all in `ConfigLoader.parse`, mirroring `gitea:` handling):

1. Route repos must be valid `RabinApps/name` scopes; no duplicate repo across routes.
2. If a route's runtime is `tart`, the repo's OS is macOS — enforce that the forge-side label
   set for that repo includes macOS labels, or the route explicitly declares `os: macos`.
3. `docker:` requires `image`; `max_slots` ≥ 1. `host:` requires explicit labels (never default
   silently) and its consent acknowledgment in the UI before the config may contain it.
4. `runtimes.default` must be an available runtime; if `tart` is never referenced by any route
   or the default, the Tart checklist rows are **omitted** (that's what makes Tart optional).

## 5. Capacity planning goes per-runtime

`Capacity.plan` stays the single math choke point and gains sibling plans. The host budget is
partitioned:

```
Host budget (cores, RAM, disk) — after reserve:
  ├── macOS budget  → Capacity.plan(vm shape)      → tart VM cap (today's math)
  ├── Linux budget  → Capacity.plan(linuxVM shape) → linux-VM cap, × docker max_slots per VM
  └── host budget   → a simple hostConcurrency cap (config), no virtualization cost
```

- `DockerRuntime`'s effective job cap = `min(linuxVMCap × max_slots, sum of per-route max_slots)`.
- The engine's autoscaler input becomes a per-runtime demand/capacity matrix: demand assigned to
  a repo's route uses _that route's_ runtime cap, not the global one. `FleetStatus` gains
  `capacityByRuntime: [String: Int]?` so `kinhin doctor`/status can show
  `tart: 2 · docker: 12 slots · host: 2`.
- Overcommit is impossible by construction: budgets partition, they never share.

## 6. Engine integration (the seam list)

The engine keeps one reconcile loop and one lifecycle per record; runtime-ness becomes a
parameter on the paths that already branch by platform:

1. `VMRecord` gains `runtime: String?` alongside `platform` (same Codable-optional pattern).
2. Spawn: assign **runtime from the repo's route** (first-match config lookup), _after_ the forge
   demand split — a repo's demand counts against its runtime's capacity.
3. `runLifecycle`: `provision` + `registrationScript` + `watch` + `teardown` calls replace the
   direct `tart.*` calls, parameterized by `record.runtime` (default `tart`).
4. `recoverIfNeeded`: VMs adopt `runtime: tart` for backward compatibility; a record whose
   runtime no longer has a route is deleted on recovery (config changed underneath).
5. `deleteVMRecord`: runtime-specific cleanup via `teardown`, plus existing forge cleanup.
6. Host warm runners live outside the record store (not spawned/deleted per job); they're
   reconciled in `attachRuntimesIfNeeded()` — started/stopped to match routes, shown in status
   as `warm:` entries.

## 7. UI: where-to-run picker

A **Runtimes** pane in the menu bar app (Settings window, mirroring Setup's card machinery):

- One card per configured repo (from the forge scope + routes): repo name, current runtime chip,
  and a picker (Tart / Docker / Host).
- Host picks require a consent checkbox ("Run this repo's code directly on my Mac, unisolated")
  before Save enables.
- Save writes the `runtimes:` section through the existing validated-config path, then re-runs
  the checklist — rows appear/disappear per selected runtime (Docker row only when a Docker
  route exists; Tart rows omitted entirely when tart is unrouted).
- Prerequisite cards per runtime follow the existing `SetupCheckResult` contract:
  `runtime-tart`, `runtime-docker`, `runtime-host` rows with fix actions.

## 8. Staged implementation plan

| Stage | Deliverable                                                                                                                                                                                                                                                                | Effort       | Risk                                       |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | ------------------------------------------ |
| 1     | `Runtime` protocol + `TartRuntime` wrapping today's calls; engine refactor behind it; **all ~760 tests green**                                                                                                                                                           | 1 session    | low — pure refactor                        |
| 2     | Routing config (`runtimes:` section), per-runtime capacity matrix, `FleetStatus.capacityByRuntime`                                                                                                                                                                         | 1 session    | medium                                     |
| 3     | `DockerRuntime` (Linux VM infra detection, slot containers, `docker exec` registration, teardown) + tests — **shipped**: daemon-agnostic health via `docker info`, per-slot `--cpus/--memory`, `docker exec` registration, checklist/doctor rows, `image prepare --docker` | 1–2 sessions | medium — Docker Desktop vs colima variance |
| 4     | `HostRuntime` warm runners + consent flow + status `warm:` entries                                                                                                                                                                                                         | 1 session    | low code / high care                       |
| 5     | Runtimes settings pane (picker UI writing config, checklist rows per runtime)                                                                                                                                                                                              | 1 session    | low                                        |
| 6     | Docs + doctor sections per runtime                                                                                                                                                                                                                                         | ½ session    | low                                        |

Stages 1–2 land invisibly (no user-visible change); stage 3 is the first user-facing feature.

## 9. Risks & mitigations

1. **Docker-on-macOS variance** (Docker Desktop vs OrbStack vs colima socket paths, VM waking):
   spike first, `RuntimeHealth.missing` with a fix hint when no socket answers, and the Linux VM
   counted in capacity so a sleeping Linux VM can't silently strand jobs.
2. **Host-mode safety**: consent gate + loud checklist row + status marker; work dirs scrubbed
   per job; label-scoped so only explicitly opted-in repos can dispatch.
3. **Capacity regressions**: every existing `Capacity.plan` test keeps passing unchanged — the
   partition is additive; new per-runtime matrix tests pin the split.
4. **Config migration**: no `runtimes:` key → behavior identical to today (everything tart);
   template comment documents the section; validation errors are actionable like `gitea:`'s.
5. **Scope creep guard**: Forgejo/GitLab forges and GitLab runners stay out of scope here; the
   runtime layer composes with them later by design.

## 10. Open questions

1. Should the shared Linux VM be kinhin-managed or delegate to Docker Desktop's? (Recommendation:
   delegate to the installed Docker provider; manage nothing.)
2. Per-route `runners_per_vm`? v1: inherit the global value; per-route override only if a real
   workload demands it.
3. Should host-mode warm runners count against `max_runners`? Recommendation: yes, with their
   own cap so one host repo can't starve the VM pool.
