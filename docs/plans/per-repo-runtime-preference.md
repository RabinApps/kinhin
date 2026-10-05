# Plan: per-repo runtime preference in `.kinhin.yml`

## Goal

Let each repo declare its preferred runtime and per-workflow runtime overrides in its `.kinhin.yml`, gated by the existing `projects[].repo_file: true` opt-in. This sits below explicit fleet routes and above the fleet default in precedence, and `runs-on:` stays the most-specific per-job override. Host mode stays fleet-controlled. Mixed-workflow repos (some workflows macOS, some Linux) can route each workflow without the fleet owner maintaining a route per workflow.

This extends the existing repo-file mechanism (which already handles per-project toolchains via `.kinhin.yml`) to also cover routing, using the same opt-in, same fork-PR exclusion, and same forge-file-API availability constraints.

## Design

### Granularity

- **Per-job** — `runs-on:` in the workflow. Already works. Most specific.
- **Per-workflow within a repo** — `.kinhin.yml routes[].workflow` (new). Routes a workflow by name to a runtime.
- **Per-repo default** — `.kinhin.yml runtime:` (new). Default runtime for the repo's jobs that don't match a workflow route and don't carry an explicit pool-selecting label.
- **Per-step** — not a routing concern. A step that needs a different runtime belongs in a separate job. Within a job, a step that needs different tools uses `kinhin-toolchain install` (already supported) or the repo's declared toolchains.

### Precedence (final)

1. `config.yaml runtimes.routes[]` — explicit fleet routes (fleet-controlled). Win over everything below.
2. `runs-on:` label unique to one pool — label-based pool selection (includes the exclusive markers `kinhin-tart`, `kinhin-container`, `kinhin-docker`, `kinhin-host`, plus any label present on exactly one pool, e.g. `linux` when only a tart Linux image provides it).
3. `.kinhin.yml routes[].workflow` — repo per-workflow routes (repo-controlled, opt-in).
4. `.kinhin.yml runtime:` — repo default (repo-controlled, opt-in).
5. `config.yaml runtimes.default` — fleet default (fleet-controlled).

Step 2 generalizes today's exclusive-marker step. Today only `kinhin-container`/`kinhin-docker`/`kinhin-host` (markers unique to one pool) trigger step 2; tart has no marker, so `runs-on: [self-hosted, macos, arm64]` falls through to the default. The change: (a) add `kinhin-tart` as tart's exclusive marker so jobs can explicitly request tart, and (b) generalize step 2 to any label present on exactly one pool, so `runs-on: [self-hosted, linux]` routes to the tart pool when a Linux-named image (which carries `linux`) is the only pool advertising `linux`.

Steps 3–4 only apply when the matching project has `repo_file: true` and the job is not a fork PR and the forge can supply the file (GitHub, Gitea, GitLab). Otherwise they are skipped and the decision falls to step 5.

### Why not move the whole `runtimes:` section into the repo file

Budget, the global default, and host-mode consent are fleet-owner decisions (shared resources, global fallback, unisolated execution). Those stay in `config.yaml`. The repo file only declares the repo's own _preference_ (default runtime + per-workflow overrides), which the fleet owner opts into. Explicit fleet routes always win, so the fleet owner retains full overridecontrol.

### Backward compatibility

- Existing repo files (toolchains only) are unaffected — they have no `runtime:`/`routes:` keys, so no routing preference is produced.
- `repo_file: true` already exists; it gates both toolchain and runtime file reads. A project without it gets no repo-file routing (falls to fleet default), same as today.
- Adding `kinhin-tart` to tart runners' labels is safe: extra runner labels never break existing job→runner matching (the forge requires the runner to have all the job's labels; extra runner labels are fine).

## Implementation

### 1. Repo-file schema — `ProjectFileLoader`

**File:** `Sources/KinhinKit/Config/ConfigLoader+Projects.swift` (the `ProjectFileLoader` enum)

- Add `"runtime"` and `"routes"` to `allowedTopLevelKeys` (alongside `"toolchains"`).
- Parse `runtime:` as an optional `String`.
- Parse `routes:` as an optional array of `{ workflow: String, runtime: String }`.
- Validate:
  - `runtime:` value, if present, must be one of `tart`, `appleContainer`, `docker` (non-host). `host` is rejected with a clear message (host is fleet-controlled).
  - Each `routes[].runtime` value: same non-host validation.
  - Each `routes[].workflow`: non-empty string.
  - Keep the existing 16 KB cap, UTF-8 check, YAML parse, and catalog-only toolchain rule unchanged.
- Return a new combined type instead of `ToolchainsConfig?`:

```swift
public struct ProjectFileResolution: Sendable, Equatable {
    public let toolchains: KinhinConfig.ToolchainsConfig?
    public let runtime: String?                       // .kinhin.yml runtime:
    public let routes: [ProjectFileRoute]            // .kinhin.yml routes:
    public let warning: String?
}
public struct ProjectFileRoute: Sendable, Equatable {
    public let workflow: String
    public let runtime: String
}
```

- `ProjectFileLoader.parse(_ data:) throws -> ProjectFileResolution?`.
- Update the one caller (`ProjectToolchainResolver.resolve`) to read `.toolchains` from the `ProjectFileResolution`. (Or keep a backward-compat `parseToolchains` if the change is disruptive — but there's only one caller, so updating it is fine.)

### 2. Repo runtime resolver — new file

**File:** `Sources/KinhinKit/Images/ProjectImages/ProjectRuntimeResolver.swift` (new, parallel to `ProjectToolchainResolver`)

- `ProjectRuntimeResolution`: `defaultRuntime: String?`, `routes: [ProjectFileRoute]`, `source: Source`, `warning: String?`.
- `Source`: `.repoFile`, `.none`.
- `resolve(repository: projects: forge: job: cache:)`:
  - Find the matching project (mirror `ProjectToolchainResolver.project(for:in:)`).
  - If no project, or `project.repoFile == false`, or `job.isFork` → return `.none` (no preference).
  - If `forge.projectFile` is unavailable (nil-returning forge: Buildkite, Bitbucket, Azure DevOps) → `.none`.
  - Fetch the file via `forge.projectFile(repository: job.repository, ref: job.ref)` (async). Use a per-(repository, sha) cache across the reconciliation pass; mirror/reuse the pattern from the toolchain side (check `ProjectToolchainSource.swift` during implementation for the existing cache).
  - Parse with `ProjectFileLoader.parse`.
  - Return `ProjectFileResolution` as the resolution (`.runtime`, `.routes`, `.warning`).
- Fork PRs never honored (same as toolchains). If the resolver can't tell fork vs not (some forges), treat as not honored — conservative.

### 3. Routing — `RuntimeRouter` and `RuntimeConfigModel`

**Files:** `Sources/KinhinKit/Runtimes/RuntimeRouting.swift`, plus engine files below.

#### 3a. Add `kinhin-tart` as tart's exclusive marker

**File:** `Sources/KinhinKit/Runtimes/RuntimeRouting.swift`, `RuntimePool.exclusiveMarker(for:)`

- `case .tart: return "kinhin-tart"` (was `default: return nil`).

This gives tart an explicit opt-in label, symmetric with the other pools, and lets step 2 route explicitly to tart.

#### 3b. Generalize label-based pool selection (step 2)

Replace today's exclusive-marker loop in `RuntimeRouter.assign` with a general rule:

- Build the set of the job's `runs-on:` labels (lowercased).
- For each label, count how many pools advertise it (lowercased match). If exactly one pool has it, that pool is "uniquely targeted."
- If exactly one pool is uniquely targeted by the job's labels, route there (this covers `kinhin-container` → appleContainer, `kinhin-docker` → docker, `kinhin-host` → host, `kinhin-tart` → tart, and `linux`/`xcode`/etc. when unique to tart).
- If zero or more than one pool is uniquely targeted, fall through to step 3.
- Keep a `via:` label like `"label:appleContainer"` for logging.

This subsumes the existing exclusive-marker behavior and extends it. A job with `runs-on: [self-hosted, linux]` routes to the tart pool when a Linux-named image is the only pool carrying `linux`; a job with `runs-on: [kinhin-container]` still routes to appleContainer; a job with `runs-on: [self-hosted, macos, arm64]` (labels on multiple pools) falls through.

#### 3c. Add repo preference (steps 3–4)

- Give `RuntimeConfigModel` an optional repo-preference provider:

```swift
let repoPreference: ((ForgeJob) -> ProjectRuntimeResolution?)?
```

- In `assign` (and `runtime(for:)` / `demandByPool` which call `assign`), after step 2 and before step 5:
  - If `repoPreference` is nil → skip steps 3–4.
  - Otherwise call `repoPreference(job)`. If nil → skip.
  - Step 3: if the resolution has `routes`, find a route whose `workflow` matches the job's workflow name (case-insensitive, mirroring `RuntimeRouter.workflowKey`/`workflow(of:)`). If exactly one match, route to that runtime's pool (if the pool exists; if the runtime isn't configured, skip the route and fall through with a warning surfaced via the resolution's warning).
  - Step 4: if no workflow route matched and the resolution has a `defaultRuntime`, and that runtime's pool exists, route there.
- `via:` strings: `"repo-workflow:<workflow>"`, `"repo-default:<runtime>"`.

The provider is nil for the `RuntimesPaneViewModel` construction (the pane only displays pools/routes, doesn't route jobs), so the pane is unaffected.

#### 3d. Engine — provide the repo-preference provider and resolve per job

**Files:** `Sources/KinhinKit/Fleet/FleetEngine.swift`, `Sources/KinhinKit/Fleet/FleetEngine+Reload.swift`

- When constructing `RuntimeConfigModel`, provide `repoPreference` as a closure that, given a `ForgeJob`:
  - Looks up the matching project from `config.projects` (project for `repository`).
  - If no project or `project.repoFile == false` or `job.isFork` → nil.
  - Delegates to `ProjectRuntimeResolver.resolve(...)` (which does the file fetch + parse + cache).
- To avoid async-in-sync issues, resolve repo preferences for queued jobs _before_ routing:
  - In `reconcileOnce` (or the routing-dispatch site), for each queued job that might need a preference (has a matching `repoFile: true` project, not a fork, forge supports files), resolve the preference (concurrently, deduplicated by `(repository, sha)`).
  - Build a `[ForgeJob: ProjectRuntimeResolution?]` map (or a function closed over it).
  - Pass each job's resolution into `RuntimeConfigModel.repoPreference` as a closure that looks up the map by job identity (e.g. by `job.name`/`repository`/`ref` tuple, or by job pointer if stable).
- If the file fetch fails or parses with a warning, surface the warning (log + diagnostics), and treat as no preference (fall to fleet default). Don't fail the job — the repo file is untrusted and may reference an unavailable runtime.

Practical note: the file is fetched per `(repository, ref)` since different jobs in the same repo may be at different refs. Cache per `(repository, sha)` within the pass; the ref→sha mapping comes from `ForgeJob.sha`/`ref`. If a forge omits sha, cache by ref and accept that two jobs at the same ref-name but different commits share a fetch (acceptable; the file is the same path at the same ref-name).

### 4. Validation — `ConfigLoader` and project-file loader

**Files:** `Sources/KinhinKit/Config/ConfigLoader.swift`, `Sources/KinhinKit/Config/ConfigLoader+Projects.swift`

- `ProjectFileLoader` validation: reject `runtime: host` and `routes[].runtime: host` in the repo file (host is fleet-controlled; see security). Reject empty workflow names.
- `ConfigLoader`: no new `config.yaml` keys are required if we reuse `repo_file` to gate both toolchains and runtime reads. So no new validation in `ConfigLoader` for the flag itself. But add a validation note: if a repo file's `runtime:` or a route's `runtime:` names a runtime that is not configured in the fleet (e.g. `docker` with no `docker:` section), the resolver skips that preference and falls back with a warning (don't fail the job; the fleet config is the source of truth for what's available).
- Keep the existing `runtimes.routes` validation (host consent gate, pattern format, duplicate patterns, unknown runtimes, budget sum) unchanged.

### 5. Config template

**File:** `Sources/KinhinKit/Config/ConfigTemplate.swift`

- In the `projects:` example, show `repo_file: true` and note that the repo's `.kinhin.yml` may now also declare `runtime:` and `routes:` (in addition to `toolchains:`).
- In the `runtimes:` template area, note that per-repo runtime preference can live in each repo's `.kinhin.yml` when `repo_file: true`, and that `config.yaml runtimes.routes[]` overrides it.
- Keep `runtimes:` commented out (as today) but mention the repo-file alternative.

### 6. UI (optional, lower priority)

**Files:** `Sources/kinhin-app/UI/SwiftUI/Runtimes/`, `Sources/kinhin-app/UI/SwiftUI/Toolchains/`

- The Advanced → Routing tab shows explicit `config.yaml` routes. Repo-file routes are implicit (opted in by `repo_file: true`); showing them in the pane is a nice-to-have for transparency but not required for the feature. If done, list them under the routes section with a "from .kinhin.yml" source tag, read-only, with a link to the repo file.
- The Toolchains pane already shows repo-file status (`.kinhin.yml honored` / ignored). No change required, but the `.kinhin.yml` examples shown could mention `runtime:`/`routes:` as additional allowed keys.
- Defer UI additions to a follow-up if time is limited; the feature works without them.

### 7. Edge cases

- Repo file `runtime: appleContainer` but no `container:` section configured → skip preference, fall back to fleet default, warn.
- Repo file `routes[].runtime: docker` but no `docker:` section → skip that route, fall through, warn.
- Repo file `runtime: host` / `routes[].runtime: host` → reject at parse time (clear error in the file's warning).
- Repo file with `runtime:` but the runtime is valid yet the pool has no runners available at runtime (e.g. `appleContainer` when the container service is down) → route to the pool anyway; the pool's health handles availability (same as today).
- Multiple repo-file routes matching the same workflow → first wins (mirror config routes).
- Repo file `runtime:` value is empty or missing → treat as no default.
- Repo file has `runtime:` and `toolchains:` both → both parsed; orthogonal.
- Single-pool fleet (only tart) → step 2 uniquely targets tart for any present label; repo preference still applies but is moot (only one pool).
- Job `runs-on:` labels that match no pool uniquely and match no repo workflow route and no repo default → fleet default.

### 8. Tests

**New/updated test files:**

- `Tests/KinhinKitTests/Config/ProjectFileLoaderTests.swift` (or extend existing project-file tests): valid repo files with `runtime:`, `routes:`, both, toolchains+`runtime`, `runtime: host` rejection, `routes[].runtime: host` rejection, empty workflow rejection, unknown top-level key rejection (still rejected), 16 KB cap, UTF-8.
- `Tests/KinhinKitTests/Images/ProjectRuntimeResolverTests.swift` (new): resolution when opt-in and file present, no-op when `repo_file: false`, no-op for fork PRs, no-op when forge has no file API, resolution of `runtime:` and `routes[]`, warning propagation for unconfigured runtime, file-not-found → no preference.
- `Tests/KinhinKitTests/Runtimes/RuntimeRoutingTests.swift` (extend): label-based pool selection for `kinhin-tart`, `kinhin-container`, `linux`-unique-to-tart, `macos`-on-multiple-pools (no selection), ambiguous unique labels (fall through); repo workflow route matching; repo default; precedence order (explicit route > label selection > repo workflow route > repo default > fleet default); repo preference skipped when provider is nil.
- `Tests/KinhinKitTests/Fleet/` (as needed): a reconciliation-level smoke test that queued jobs in a repo with `repo_file: true` and a `.kinhin.yml runtime:` land on the right pool; fork PRs ignored; explicit fleet route overrides repo preference.

### 9. Docs

- **`docs/runtimes.md`**: add a "Per-repo runtime preference" section explaining `.kinhin.yml runtime:` and `routes:`, the precedence, the `repo_file: true` opt-in, fork-PR exclusion, forge availability, and that `runs-on:` with exclusive markers (including the new `kinhin-tart`) or unique labels selects a pool directly. Update the comparison table and any "one OS at a time" wording is already fixed by the earlier macOS/Linux mixing change; ensure consistency.
- **`docs/toolchains.md`**: note that `.kinhin.yml` now also accepts `runtime:` and `routes:` (in addition to `toolchains:`), all gated by `repo_file: true`.
- **`docs/security.md`**: note that repo-file routing is gated by `repo_file: true`, excluded for fork PRs, and cannot declare host mode; host routes remain fleet-controlled with `consent: true`. Note that a repo's runtime preference can only route to runtimes the fleet has configured (else it's skipped with a warning).
- **`docs/app.md`**: in the routing UI section, mention that repos with `repo_file: true` can declare their runtime preference in `.kinhin.yml`, and that the fleet owner's explicit routes override it.
- **`docs/forges.md`**: note that repo-file routing (like repo-file toolchains) only works on forges that serve the file API (GitHub, Gitea, GitLab); other forges fall back to the fleet default.
- **`docs/architecture.md`**: if it lists the repo-file loader's responsibilities, add routing preference to the list.
- **`skills/kinhhin-configure/SKILL.md`**: update routing instructions to mention repo-file `runtime:`/`routes:` and the opt-in.
- **`skills/kinhin-images-toolchains/SKILL.md`**: update the `.kinhin.yml` reference to include `runtime:` and `routes:` alongside `toolchains:`.
- **`Sources/KinhinKit/Config/ConfigTemplate.swift`**: template wording as above.
- **`website/`** (if applicable): mirror the `docs/` routing prose in the website's config/runtimes guide pages; run `cd website && npx vitepress build` after.

### Order of implementation

1. `ProjectFileLoader` schema expansion + `ProjectFileResolution`/`ProjectFileRoute`, update the toolchain resolver caller.
2. `ProjectRuntimeResolver` (new).
3. `RuntimePool.exclusiveMarker` — add `kinhin-tart`; generalize `assign` label-based selection.
4. `RuntimeConfigModel` + `RuntimeRouter.assign` — repo preference steps (3–4) + provider closure.
5. Engine — resolve per-job repo preferences and pass the provider.
6. Validation + config template.
7. Tests.
8. Docs.
9. `swift build`, `swift test`, `swift format lint --strict -r Sources Tests`, `bash scripts/docs-sync.sh`, `cd website && npx vitepress build`.

### Verification criteria

- A repo with `repo_file: true` and `.kinhin.yml runtime: appleContainer` routes its jobs to the appleContainer pool when no workflow route or unique label applies, on a forge that serves the file, for non-fork jobs.
- A repo with `routes: [{workflow: "iOS Tests", runtime: tart}]` routes that workflow to tart and others to the repo default.
- An explicit `config.yaml` route overrides the repo preference.
- `runs-on: [kinhin-tart]` routes to tart; `runs-on: [kinhin-container]` routes to appleContainer; `runs-on: [self-hosted, linux]` routes to tart when `linux` is unique to tart.
- Fork PRs never use the repo file for routing (fall to fleet default).
- `runtime: host` in the repo file is rejected.
- Existing repo files (toolchains only) produce no routing preference and don't change behavior.
- `kinhin-tart` is present on tart runners and doesn't break existing job matching.
