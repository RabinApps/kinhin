# Per-project toolchains via `.kinhin.yml` and baked per-project images

## Context

Toolchains are one global `toolchains:` section (`ConfigModel.swift:72`). `image prepare` bakes them into a single image per runtime (`cfg.image`, `container.image`, `docker.image`). Every runner is a clone of that image, and the engine never learns which repo a VM serves: `RepoRoute.from(config:)` (`Runtime.swift:34`) is built from global config at `FleetLifecycle.swift:57,115`. Different projects need different versions (Go 1.22 vs 1.23, Node 20 vs 22), so toolchains must be resolved per project, per ref.

Decisions: versions are declared in a `.kinhin.yml` in the repo, resolved per repo and branch/tag (the ref the job runs at). Each distinct resolved toolchain set is baked into its own derived image.

## Design

### 1. `.kinhin.yml` (repo-side declaration)

```yaml
toolchains:           # same shape as the global section (specs/brew/stacks)
  specs: [go@1.22.5, node@20]
  stacks: [flutter@3.24.0]
```

- Only `toolchains` is accepted. No `provision_script`, no `base_image`, no `share_cache` or cache policy. Unknown keys are rejected with a clear error.
- Parsed by a new `ProjectFileLoader` in `KinhinKit/Config/` that reuses `ConfigLoader.parseToolchains` (`ConfigLoader+Toolchains.swift`), so the safe-character allowlist, stack ids and requirement rules apply unchanged. Add a size cap (for example 16 KB).
- Branch- and tag-specific behavior comes from reading the file at the job's own ref, so each ref carries its own versions with no extra schema. A `.kinhin.yml` that is absent at that ref means "use the global toolchains".

### 2. Trust boundary (config stays authoritative)

A repo file makes untrusted input drive what gets installed on the host, so it is opt-in:

```yaml
projects:             # new top-level section in config.yaml
  - pattern: "acme/*"        # same pattern grammar as routes
    repo_file: true          # honor .kinhin.yml for matching repos (default false)
    toolchains: {…}          # optional fallback/default for matching repos
    share_cache: false       # per-project override (default: inherit global)
```

- Resolution order for a job: `.kinhin.yml` at ref (if `repo_file`) → matching `projects[].toolchains` → global `toolchains`.
- Only catalog tools/stacks and allowlisted mise specs are ever installed. Fork PRs never get `repo_file` honored: the file is read from the base repo's default branch for forks. Cap the number of distinct derived images (config `max_project_images`, default 8), with LRU eviction.

### 3. Getting the ref and the file to the engine

- `ForgeJob` (`Forges/Forge.swift:186`) gains `ref: String?` (branch or tag) and `sha: String?`. Populate them in `GitHubClient+Runs.swift` (`head_branch`/`head_sha` are on the run), Gitea and GitLab where available, and nil elsewhere (Buildkite, Bitbucket, Azure fall back to global).
- Add `Forge.projectFile(repository:ref:) async throws -> Data?` with a default `nil` implementation, and implement it for GitHub (contents API), Gitea, GitLab. Reuse the existing `withTransientRetry` and the rate-budget accounting from `91f2696`. Cache by `(repo, sha)` to avoid repeated API calls while a job queues.
- Failure policy: fetch or parse errors are logged and surfaced in Diagnostics, and the job falls back to the global image. They never block the fleet.

### 4. Image identity and baking

- New `ToolchainImageKey`: `sha256(canonical ManagedToolchainSelection + base image digest + platform)`, truncated. The derived name is `<runtime image>-p<8 hex>` (for example `tahoe-base-p3a9f12c4`). Identical selections across repos share an image.
- `ImagePreparer`/`LinuxImageBaker` already take `Options.target` and a local-VM `source` (`ImagePreparer.swift:146`). A project bake clones the **global base image** (so base layers/agents are reused), runs only the managed-toolchains step (`:275-302`), skips the user provision script, and writes the derived target. Extract that step into a reusable `ProjectImageBuilder` in `KinhinKit/Images/`, and wrap it in an actor that serializes builds and de-duplicates concurrent requests for the same key.
- `ImageBuildService` (`Images/ImageBuildService.swift`) gains `rebuild(runtime:, selection:)`.
- Prune: a `ProjectImageStore` tracks derived images (a JSON index under `Paths` app support with last-used time). `CleanupCommand` and the daily sweep (`FleetEngine+Control.swift:103`) remove images beyond `max_project_images` or unused for N days. Global image rebuild invalidates derived images (the key includes the base digest).

### 5. Demand and spawn-time binding

This is the hardest seam. Today `spawn` picks a runtime from aggregate demand and the VM is not bound to a job.

- `RuntimeConfigModel.demandByPool` (`RuntimeRouting.swift:213`) buckets by `(runtime, imageKey)` instead of `runtime` alone. `RuntimeRouter.assign` already sees `job.repository`; add the resolved `imageKey`.
- `pollDemand` (`FleetReconcile.swift:~202`) resolves each queued job's project selection (section 3), then asks the build actor for the image: **ready** → demand goes to that image's pool; **building/absent** → kick off a bake and meanwhile route the job to the global image (the job can still call `kinhin-toolchain install`), so a job is never stalled on a bake.
- `VMRecord` (`Fleet/Fleet.swift:25`) gains `image: String?` so lifecycle, crash recovery and adoption re-derive the right image. Add this as a backward-compatible optional field.
- `RepoRoute.from(config:)` becomes `RepoRoute.from(config:, record:)`. It sets `image` from the record and carries per-project `cacheMount`. `TartRuntime.provision` already honors `route.image` (`Runtime.swift:183`). `LinuxContainerCLI`, `AppleContainerRuntime` and `DockerRuntime` currently ignore it and must honor it.
- Registration-time cache env exports (`cachedToolchainSelection`, `linuxToolchainSelection`) take the selection from the route rather than the engine-wide `toolchainsConfig` closure (`FleetEngine.swift:126`).
- Reload: add `projects` to the keys that `restartRequired` handles (`FleetEngine+Reload.swift:12`), then hot-apply, since it only affects routing and new spawns. Update `ReloadRestartPolicyTests`.

### 6. Cache and security

- `share_cache` becomes per-project (default inherits global; forced off for fork PRs). Scope the cache subpath by project (`ToolchainCacheMount` gains an optional subdir) so untrusted repos can't poison each other. `ToolchainCachePruner` already prunes by subdirectory.
- Update `docs/security.md` and Doctor/Setup (`DoctorReport.ToolchainCacheSection`, `SetupStatusComputer`) to report per-project state.

### 7. UI and CLI

- CLI: `kinhin toolchains --project owner/name [--ref X]` resolves and prints the effective selection and image key. `kinhin image prepare --project owner/name [--ref X]` bakes it eagerly (warm start). `kinhin toolchains list-images` and `prune` handle derived images. Follow `ToolchainsCommand.swift` and `ImageCommand.swift` patterns, with errors through `fail(_:exit:)`.
- App: **remove the global toolchain picker.** Delete the selection editor in `ToolchainsModel`/`ToolchainsView` (categories, stacks, extras cards, `ToolchainsConfigEditor.apply` write path) and the wizard's "Select your toolchains" step (`WizardModel`, `WizardView`, `ToolchainsAllOffSeedTests`). Replace the Advanced → Toolchains tab with:
  - **Available toolchains:** a read-only browser of `ToolchainCatalog` (tools and stacks, default versions, platform support, requirements), each with a copy button.
  - **Examples:** copyable `.kinhin.yml` snippets (Go + Node, Flutter stack, Linux vs macOS notes), plus a short "how it works / when images get baked" explainer.
  - **Projects:** `projects:` patterns with the `repo_file` toggle, and derived images (size, last used, delete, rebuild). `projects` editing goes through a new `ProjectsConfigEditor` modeled on `RuntimesConfigEditor`.
- Global config: the top-level `toolchains:` key is **kept only as the fallback** for repos with no `.kinhin.yml` and no matching `projects[].toolchains`, and is hand-edited in YAML (documented, not in the UI). `kinhin image prepare --toolchain/--stack` stays for baking the global fallback. Do not remove the key, since existing configs depend on it. `ToolchainsConfigEditor`/`ToolchainsSelection` stay in `KinhinKit` only if `ProjectsConfigEditor` or the CLI still use them, otherwise delete.
- The setup checklist's toolchain items and Doctor remain, and are reworded to refer to per-project images.
- Errors go through `AlertKit.present(error:)`, per CLAUDE.md.

### 8. Docs

Edit `docs/toolchains.md` (new "Per-project toolchains" section, `.kinhin.yml` reference), `docs/security.md`, `docs/architecture.md`, `docs/forges.md` and the config template (`ConfigTemplate.swift:82`). Check with `cd website && npx vitepress build`.

## Phasing (each phase builds and tests green; mechanical moves in separate commits)

1. Refactor: extract the managed-toolchains bake from `ImagePreparer`/`LinuxImageBaker` into `ProjectImageBuilder`. `RepoRoute` carries `image`, selection and `cacheMount`, honored by all runtimes. No behavior change.
2. Config: `projects:` schema, `ProjectFileLoader`, `ToolchainImageKey`, `ProjectImageStore`. Pure `KinhinKit`, unit-testable.
3. Forge plumbing: `ForgeJob.ref/sha`, `Forge.projectFile`, GitHub first, then Gitea and GitLab.
4. Engine: demand bucketing by image key, build actor, `VMRecord.image`, fallback to global while baking, reload policy.
5. CLI and app surfaces: remove the global picker and wizard step, add the catalog/examples/projects tab, then cleanup/prune and Doctor.
6. Docs.

## Critical files

`Config/ConfigModel.swift`, `ConfigDTO.swift`, `ConfigLoader*.swift`; `Forges/Forge.swift`, `GitHubClient+Runs.swift`; `Images/ImagePreparer.swift`, `LinuxImageBaker.swift`, `ImageBuildService.swift`; `Runtimes/Runtime.swift`, `RuntimeRouting.swift`, `LinuxContainerCLI.swift`, `DockerRuntime.swift`, `AppleContainerRuntime.swift`; `Fleet/FleetReconcile.swift`, `FleetLifecycle.swift`, `Fleet.swift`, `FleetEngine+Reload.swift`; `Cache/ToolchainCachePruner.swift`; CLI `ToolchainsCommand.swift`, `ImageCommand.swift`; app `Toolchains/ToolchainsModel.swift`.

## Verification

- `swift build`, `swift test`, `swift format lint --strict -r Sources Tests`, and `scripts/tsan.sh` (the build actor and `ProjectImageStore` are shared state).
- New tests, mirroring source folders: `ProjectFileLoaderTests` (valid file, unknown keys, injection strings, oversize), `ToolchainImageKeyTests` (stable hash, order-independent, base digest sensitivity), `ProjectImageBuilderTests` with `FakeTart`/`FakeShell` (clone from base, skips provision script, failure keeps previous), routing tests (two repos with different `.kinhin.yml` yield two pools; the same selection shares one image; fork PR ignores the file; baking falls back to global), `VMRecord` Codable backward compatibility, `ReloadRestartPolicyTests`, and `FakeGitHub` contents fetch with the cache.
- End to end on a Mac: `scripts/dev-run.sh`, set `projects: [{pattern: me/repoA, repo_file: true}]`, push `.kinhin.yml` with `go@1.22.5` on one branch and `go@1.23.4` on another, run `kinhin toolchains --project me/repoA --ref <branch>`, trigger workflows that print `go version`, and confirm each runs on its own derived image. Then confirm `kinhin cleanup` removes them.

## Storage cost of derived images

On this machine `tart list` shows `tahoe-base` at 33 GB on disk (50 GB logical). A tart clone is an APFS copy-on-write clone, so a derived image only costs the blocks that change. Expect the toolchain delta (a few GB per set: Go about 0.5 GB, Node about 0.3 GB, Flutter and Xcode-adjacent stacks 5 GB or more), not another 33 GB. This is an estimate and not measured, and `du` and `tart list` over-report because they count shared blocks per image. The `max_project_images` cap and LRU pruning bound the total. Caveats:
- If the base image is rebuilt, derived images keep the old base blocks until pruned, so peak usage can briefly be base × 2.
- Apple `container` has no commit, so it exports and rebuilds `FROM scratch` and gets no layer sharing: each derived Linux image is full size. Docker commits share layers.
- Phase 2 should measure real deltas (`tart list` before and after one derived bake) and show per-image size in the Projects card and `kinhin toolchains list-images`.

## Open risks

- The build actor and bake-while-fallback behavior needs a clear user-visible state ("baking image for acme/api, using base meanwhile") in Diagnostics.
- Forges without a ref or file API (Buildkite, Bitbucket, Azure) only get `projects[].toolchains` fallback, not `.kinhin.yml`.
- API budget: one extra contents call per distinct `(repo, sha)`, which is covered by the cache above.
