# Toolchains & the shared cache

How to get Go, Node, Xcode, Flutter and friends onto kinhin runners: bake them into the base
image, declare them per project and let kinhin bake an image for each, or install them per job,
and share a download cache across all of it.

[← Back to README](../README.md)

## Baking toolchains into the base image

GitHub-hosted runners ship with Xcode, JDKs, Go, Rust, and dozens of other tools preinstalled.
kinhin's runner VMs contain exactly what the base image contains — each job gets a fresh
linked clone of it, so anything a job installs is thrown away when the VM is deleted. The
place to add your own toolchains is `kinhin image prepare`: it can run **your provision
script** inside the VM once, after the runner agents are installed, and every runner VM then
boots with whatever it installed.

Write a script — it runs verbatim as the `admin` user, and a failure aborts the prepare with
the previous image left intact:

```bash
#!/bin/bash
# ~/kinhin/provision.sh — baked into the image by `kinhin image prepare`
brew install wget cmake
mise install go@1.23.4 rust@1.82 java@temurin-21   # exact versions; mise ships in the base image
go version && rustc --version && java -version      # their output is logged as the audit trail
```

Wire it up either way (the CLI flag wins over the config key):

```bash
kinhin image prepare --provision-script ~/kinhin/provision.sh
```

```yaml
# config.yaml
provision_script: "~/kinhin/provision.sh"
```

- **Versioning is yours.** The script is the pin: every prepare rebuilds from the pristine
  upstream image, so editing the script and re-running prepare is how toolchains change —
  there is no drift between builds. The base image ships **Homebrew** and **mise**, so either
  `mise install go@1.23.4` (exact patches) or versioned formulas like
  `brew install go@1.23 temurin@21` (pinned major/minor) work.
- **Audit trail.** End the script with `go version && java -version …` — kinhin logs the
  stdout tail during prepare, recording what went into that image build (see `kinhin logs`).
- **Checklist guard.** A configured script that is missing or empty fails the first-run
  checklist (`kinhin setup-status` / the setup window) with a one-click fix, so the typo is
  caught before a 20-minute prepare downloads gigabytes and then aborts.
- **Timeout.** The script gets its own 30-minute budget, separate from the agent install.
- **Full Xcode?** Don't install it from a script (it's tens of GB) — point `image:` (or
  `image prepare --source`) at Cirrus Labs' `macos-tahoe-xcode:16` or `macos-runner:tahoe`
  images instead: Xcode (and Flutter) preinstalled, with `xcodes` to switch versions.
- **Small tools only?** Per-job `actions/setup-go`, `actions/setup-java`,
  `dtolnay/rust-toolchain`, and friends still work on kinhin runners and need no image
  work — at the cost of re-downloading the toolchain in every job.

## Managed toolchains

Instead of writing a provision script, declare the runtimes you want and let kinhin install,
pin and verify them. Toolchains are always **per project**: there is no global toolchain list,
and each project's versions are independent. They are declared either by the repo in a
[`.kinhin.yml`](#the-kinhinyml-file) or by you under a [`projects:`](#the-projects-section) entry
in `config.yaml`:

```yaml
# config.yaml
projects:
  - pattern: "acme/api"
    toolchains:
      specs: ["go@1.23.4", "node@22", "bun@1.1.27", "deno@2", "java@temurin-17", "dotnet", "uv"]
      brew: ["wget", "cmake", "yamllint"]
      stacks: ["flutter@3.24.0", "expo", "react-native", "vercel", "cloudflare"]
    share_cache: false
```

Jobs from a repo that no `.kinhin.yml` or `projects:` entry gives toolchains run on the plain
base image with nothing baked; they can still install tools per job with
[`kinhin-toolchain install`](#per-job-toolchains).

- **Nothing is installed implicitly.** Every entry installs exactly its own pieces. A
  stack that needs a runtime (e.g. `vercel` needs node) is a **validation error naming
  the fix** ("add `node@22` to toolchains.specs") until you select that runtime too.
- **The catalog is advisory in `config.yaml`.** In a `projects[].toolchains` entry, unknown specs
  pass through to mise and unknown brew entries to brew, so the long tail (`ghc`, `perl`, ...)
  works with zero kinhin code. A repo's `.kinhin.yml` is stricter: catalog tools only.
  Run `kinhin toolchains` to see the curated list.
- **Verification is the audit trail.** Each tool/stack carries a verify command
  (`go version`, `dotnet --list-sdks`, `flutter --version`...); a bake aborts with the
  previous image intact if any check fails, and the version prints land in `kinhin logs`.
- **Deploy auth stays per-job.** `VERCEL_TOKEN`, `CLOUDFLARE_API_TOKEN`, and cloud
  credentials are passed via workflow `env:` — never baked into an image.

### Migrating from a top-level `toolchains:`

The top-level `toolchains:` key is gone, and a config that still has one fails to load with:
"toolchains: is gone — declare toolchains per project: projects: [{pattern: owner/name,
toolchains: {specs: [...]}}] or let the repo declare them in a .kinhin.yml (repo_file: true)".
Also, `toolchains.share_cache` became `projects[].share_cache`, and `toolchains.cache` became the
top-level [`toolchain_cache:`](#expiry-and-pruning). Before and after:

```yaml
# before
toolchains:
  specs: ["go@1.23.4", "node@22"]
  share_cache: true
  cache: { max_gb: 20 }
```

```yaml
# after: per project (or put it in the repo's .kinhin.yml and set repo_file: true)
projects:
  - pattern: "acme/*"
    toolchains:
      specs: ["go@1.23.4", "node@22"]
    share_cache: true
toolchain_cache:
  max_gb: 20
```

Then run `kinhin image prepare` (base image) and `kinhin image prepare --project owner/name` to
bake each project's image.

### The curated catalog

Everything below installs on **both macOS and Linux** images unless marked otherwise (mise
is the cross-platform installer; Homebrew-only tools use apt or mise on Linux):

- **Languages & runtimes** (mise): node, go, rust, python, ruby, java, bun, deno, uv,
  zig, erlang, elixir, kotlin\*, scala\*, clojure\*, dart, swift, lua, julia; plus
  php and dotnet (Homebrew on macOS, apt on Linux). \*needs `java` selected too.
- **JavaScript tools** (npm globals, need node): pnpm, yarn, playwright, cypress,
  netlify-cli, firebase-tools, typescript, eslint, prettier, turbo, nx.
- **Build & quality**: cmake, ninja, maven\*, gradle\*, sbt\*, just, task, jq, yq,
  direnv, shellcheck, hadolint, yamllint, composer, and fastlane (a gem; Linux gets
  Ruby and a compiler from apt).
- **Cloud & DevOps**: terraform, opentofu, kubectl, helm, kustomize, k9s, pulumi,
  packer, vault, gh, and awscli, gcloud, flyctl, supabase (Homebrew on macOS, mise on
  Linux; a `@version` pin applies to the Linux install only).

### Curated stacks

- **`flutter[@version]`** — Flutter SDK; `@version` pins it (a release tag such as
  `3.24.0`, or a channel), default `stable`. On macOS: `fvm` (brew tap
  `leoafarias/fvm`) + CocoaPods (`fvm install` + `fvm global`). On Linux images
  (Apple container / Docker): a plain `git clone` of the SDK into `/opt/flutter`
  (no snap, no Homebrew) plus Flutter's documented prerequisites
  (`curl git unzip xz-utils zip libglu1-mesa`) and the Linux desktop toolchain
  (`clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`), put on `PATH` for
  job shells. It builds web and Linux desktop (`flutter build linux`) out of the
  box, and Android once you also select `java` and provide an Android SDK; iOS
  builds need a macOS image.
- **`expo[@eas-cli-version]`** — `eas-cli` npm-global (requires node).
- **`react-native`** — direct (no Expo): watchman + CocoaPods + JDK 17; add node
  yourself if you build JS.
- **`vercel[@cli-version]`** — `vercel` CLI (requires node); **`cloudflare[@version]`**
  — `wrangler` (requires node).

## Per-project toolchains

Different repos need different versions, so every project's toolchains are independent. A repo
can declare its own in a `.kinhin.yml` at the root of the repo. kinhin reads the file **at the ref the
job runs at** (the branch or tag), resolves the toolchain set, and bakes each distinct set into
its own derived image. Preview what a repo resolves to, and bake it ahead of time, from the CLI:

```bash
kinhin toolchains --project owner/name [--ref main]     # effective selection, source and image key
kinhin image prepare --project owner/name [--ref main]  # bake its derived image now (warm start)
kinhin toolchains list-images                           # derived images: size, last used
kinhin toolchains prune [--dry-run]                     # also sweeps derived images
```

The app's **Advanced → Toolchains** tab is read-only and has three sections: **Repos** (your
`projects:` rules and their derived images, with size, last used, delete and rebuild),
**Available toolchains** (the catalog with default versions, platform support and requirements,
each with a copy button) and **Examples** (copyable `.kinhin.yml` snippets and a short
explainer of when images get baked). There is no global toolchain picker, no setup-wizard
step and no global toolchain rebuild button: declare toolchains in a `.kinhin.yml`, or in a
`projects:` entry in `config.yaml`.

The Repos section lists each `projects:` entry with its source, its specs and stacks (or "from
.kinhin.yml at each job's ref"), and its derived images with size, last used, delete and rebuild.
A final **Other repos** row reads "no toolchains baked": those repos run on the plain base image.

### The `.kinhin.yml` file

```yaml
# .kinhin.yml (repo root)
toolchains:
  specs: ["go@1.22.5", "node@20"]
  stacks: []
```

Only a `toolchains:` section with `specs` and `stacks` is accepted. Anything else is rejected
with an error naming the key:

- No `brew`, `share_cache`, `cache`, `provision_script` or `base_image`. A repo cannot change
  cache policy, run a script, or pick the base image.
- **Catalog tools only.** Every spec must name a tool in the [curated catalog](#the-curated-catalog)
  (`kinhin toolchains` lists it). A `projects[].toolchains` entry in `config.yaml` lets unknown specs fall through to mise;
  the repo file does not, so a repo cannot pull free-form mise backends (`ubi:`, `npm:`,
  `cargo:` ...) into an image built on your Mac.
- The same [version and requirement rules](#managed-toolchains) apply: versions are limited to
  `[A-Za-z0-9._+-]`, and nothing is installed implicitly. A stack or tool that needs a runtime is
  an error until you list the runtime too.
- The file is capped at 16 KB. An empty file, or one with no specs and stacks, means "nothing
  declared" and falls through to the next level.

Examples:

```yaml
# Go service with a Node frontend
toolchains:
  specs: ["go@1.23.4", "node@22", "pnpm"]
```

```yaml
# Flutter app that also builds Android and uses Firebase tooling
toolchains:
  specs: ["java@temurin-17", "node@22", "firebase-tools"]
  stacks: ["flutter@3.24.0"]
```

The `flutter` stack has no runtime requirements of its own. `java@temurin-17` is listed because
Android builds need a JDK (Linux images also need an Android SDK you provide), and `node@22`
because `firebase-tools` is an npm global that requires node. `expo`, `vercel` and `cloudflare`
stacks likewise require `node` in `specs`. On Linux images, macOS-only pieces (CocoaPods, fvm,
the `react-native` stack) are skipped, as in any Linux bake.

Because the file is read at the job's own ref, each branch or tag carries its own versions: a
`release/1.x` branch can pin `go@1.22.5` while `main` pins `go@1.23.4`, with no extra schema. A
ref with no `.kinhin.yml` falls through to the project's own `toolchains:`, if it has one.

### Resolution order

For each job, the first level that yields toolchains wins:

1. The repo's **`.kinhin.yml` at the job's ref**, only if the matching `projects:` entry sets
   `repo_file: true`.
2. That `projects:` entry's own **`toolchains:`** (`specs`, `brew`, `stacks`).
3. Nothing: the plain base image with no toolchains baked. There is no global fallback.

A missing, oversize, unparseable or invalid `.kinhin.yml` is logged, shown in Diagnostics, and
treated as absent: the job falls to level 2 or 3. It never blocks the fleet. The file is fetched
once per repo and commit, so a queued job costs one extra API call. GitHub, Gitea/Forgejo and
GitLab supply the ref and the file. Buildkite, Bitbucket and Azure DevOps expose neither, so
their jobs only use levels 2 and 3. Fork pull requests never use the repo file; see [Security](security.md#per-project-toolchains).

### The `projects:` section

`projects:` in `config.yaml` decides which repos may use a `.kinhin.yml`. The repo file is
**opt-in**: with no entry, or `repo_file` left at its default of `false`, the file is ignored.

```yaml
# config.yaml
projects:
  - pattern: "acme/*" # owner/name, or owner/* for every repo of an owner
    repo_file: true # honor .kinhin.yml for matching repos (default false)
  - pattern: "acme/legacy-api"
    toolchains: # this repo's own toolchains (used when it has no usable .kinhin.yml)
      specs: ["go@1.21.13"]
    share_cache: false # mount the host download cache (default false)
```

| Key          | Meaning                                                                                                                                  |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `pattern`    | Required. `owner/name` or `owner/*`; no other wildcards, no `@`. Matched case-insensitively; patterns must be unique.                    |
| `repo_file`  | Honor the repo's `.kinhin.yml` (default `false`).                                                                                        |
| `toolchains` | Optional toolchains (`specs`, `brew`, `stacks`) for matching repos with no usable `.kinhin.yml`. Validated like any toolchain declaration. |
| `share_cache`| Mount the host download cache for this project's images and runners, in a subdirectory scoped to the project. Off when unset; this is the only place `share_cache` exists. Always off for fork PRs. |

`projects` changes apply to a running fleet without a restart: they only affect routing and new VMs.

### Images: naming, baking, sharing, pruning

Each distinct resolved toolchain set gets its own **derived image**, cloned from the base
image so the runner agents and base layers are reused, with only the managed-toolchains step
run on top (no provision script). Derived images are built for Tart (macOS and Linux VMs).
`kinhin image prepare` itself bakes only the base image (agents plus your `provision_script`);
toolchains are baked with `kinhin image prepare --project owner/name [--ref X]`, or on demand
when a job first needs a set. Derived images are named `<base image>-p<8 hex>`, for example
`tahoe-base-p3a9f12c4`, where the hash covers the canonical toolchain selection, the base image
digest and the platform. Two repos that resolve to the same set share one image. Rebuilding
the base image changes the digest, so derived images are rebaked rather than reused.

- **Fallback while baking.** The first job that needs a new set kicks off the bake. Until the
  image is ready, that job (and any queued behind it) runs on the base image rather than
  waiting; it can still use `kinhin-toolchain install` per job. Later jobs use the derived image.
  Diagnostics shows "baking image for acme/api, using base meanwhile".
- **Pruning.** The number of derived images is capped by the top-level `max_project_images`
  (default 8) with least-recently-used eviction, and images unused for a while age out.
  `kinhin cleanup`, `kinhin toolchains prune` and the daily sweep remove them, and the Repos
  section can delete one by hand. Pruning touches only derived images, never the base image or
  running VMs. Each runner VM records the image it was cloned from, so restarts and crash
  recovery reattach to the right one.
- **Per-image cache.** With `share_cache` on for a project, its images and runners mount the host
  cache under a project-specific subdirectory; see [the shared cache](#the-shared-download-cache).

### Storage cost

A Tart clone is an APFS copy-on-write clone, so a derived image costs roughly the blocks that
change: the toolchain delta (a few GB; Go about 0.5 GB, Node about 0.3 GB, Flutter and
Xcode-adjacent stacks 5 GB or more), not another full copy of the base. These are estimates, not
measurements. `tart list` and `du` over-report because they count shared blocks once per image,
so the sum of the sizes they print is not the disk you use. Two caveats:

- If you rebuild the base image, derived images keep the old base's blocks until they are
  pruned, so peak usage can briefly approach twice the base.
- **Apple `container` and Docker get no baked toolchains.** Derived images are a Tart feature:
  jobs on the apple/container and Docker runtimes run on the plain Linux image and install what
  they need per job with `kinhin-toolchain install`.

## Per-job toolchains

Baking suits tools every job in a project needs. For tools only some workflows need, keep the
declared toolchains lean and let each workflow install what it needs. On the apple/container
and Docker runtimes this is the only way to get toolchains. Every prepared
image (Tart — macOS or Linux — apple/container, and Docker) carries `kinhin-toolchain`, a helper
generated from the same catalog:

```yaml
jobs:
  web:
    runs-on: [self-hosted, kinhin]
    steps:
      - run: kinhin-toolchain install node@22 pnpm playwright
      - uses: actions/checkout@v4
      - run: pnpm install && pnpm test
```

- **Same recipes as the bake.** Each id runs the catalog's install and verify
  steps for the guest's platform, so a failed install fails the step.
  `kinhin-toolchain list` shows the ids available in the image, and unknown ids
  pass through to `mise use --global`.
- **Later steps see the tools.** New `PATH` entries and cache variables are
  appended to `$GITHUB_PATH`/`$GITHUB_ENV`. This works on GitHub and Gitea runners.
- **Order and requirements are handled.** Runtimes (`node`, `dotnet`, `java`)
  install first. A tool that needs a runtime you didn't list, and that isn't
  already on `PATH`, fails with the command to fix it.
- **Pair it with the project's `share_cache: true`.** Otherwise every job downloads from
  scratch. With the host cache mounted, a repeat install is mostly a cache hit.
- **Versions are validated.** Only `[A-Za-z0-9._+-]` is accepted, and an
  installer that ignores versions (brew, apt) rejects `@version` instead of
  silently dropping it.
- Audit the helper itself with `kinhin toolchains helper [--linux]`.

## The shared download cache

A host-side cache — `~/Library/Application Support/Kinhin/toolchain-cache/` — lets repeated
bakes and per-job installs skip re-downloading mise tools, brew bottles, npm packages, and
Flutter SDKs. It is mounted into a project's bake and into its runner VMs only when that
project sets `share_cache: true`. Every ecosystem gets its own env redirect at install time:

| Ecosystem               | Envs pointed at the cache                                                                |
| ----------------------- | ---------------------------------------------------------------------------------------- |
| mise / Homebrew         | `MISE_CACHE_DIR`, `HOMEBREW_CACHE`                                                       |
| npm / pnpm / yarn / bun | `NPM_CONFIG_CACHE`, `npm_config_store_dir`, `YARN_CACHE_FOLDER`, `BUN_INSTALL_CACHE_DIR` |
| Flutter (fvm, macOS)    | `FVM_CACHE_PATH`                                                                         |
| Go                      | `GOMODCACHE` + `GOCACHE`                                                                 |
| Rust                    | none (rustup cannot install onto the shared virtiofs cache, so Cargo's registry is per-VM) |
| Python                  | `UV_CACHE_DIR`, `PIP_CACHE_DIR`                                                          |
| JVM                     | `GRADLE_USER_HOME`                                                                       |
| .NET                    | `NUGET_PACKAGES`                                                                         |
| e2e browsers            | `PLAYWRIGHT_BROWSERS_PATH`, `CYPRESS_CACHE_FOLDER`                                       |

Set **`share_cache: true`** on a `projects:` entry to mount the cache, in a subdirectory scoped
to that project, into its runner VMs and bakes: per-job
installs — `npm ci`, `pnpm install`, `mise install`, `fvm install`, `dotnet restore`,
`playwright install` — then hit warm cache instead of re-downloading gigabytes per job.
This is best-effort and off by default (and always off for fork PRs): the tools tolerate concurrent VM writers (worst
case a duplicate download), but it does share cache state across ephemeral jobs.

> **Security: don't enable it for untrusted code.** The cache is mounted writable, and it holds
> things other jobs _execute_ — Cargo's `bin/`, fvm's Flutter SDKs, Playwright and Cypress
> browsers, Gradle init scripts. A job from a fork PR can plant a binary there that a later job
> from a different repository runs, and the next bake can carry it into an image. Per-project
> cache subdirectories keep repos from poisoning each other. Leave `share_cache` off (the default) on a fleet that runs outside contributors' PRs,
> or restrict that fleet to repositories whose code you trust.

### Linux runtimes

Tart Linux VMs follow the same rules as macOS: derived images, per-project `share_cache`, and a
Linux-specific bake script (apt for dotnet, mise bootstrapped on demand, npm globals; macOS-only
entries like brew tools, fvm, and CocoaPods are skipped with a note). The
[apple/container and Docker runtimes](runtimes.md#choosing-a-linux-runtime) bake no toolchains:
their jobs use per-job `kinhin-toolchain install`, and a project with `share_cache: true` gets
the host cache bind-mounted at `/var/kinhin-cache` with the guarded cache-env exports in the
runner's registration script. `kinhin doctor` reports the cache's size, per-ecosystem breakdown
and each project's share state (human output and the `toolchainCache` section of `--json`).

### Expiry and pruning

The cache auto-expires — default 30 days since last use, with LRU eviction past 50 GB —
and a one-hour grace window means a prune can never race a live download. Tune or
disable it under the top-level `toolchain_cache:` section, sweep manually with
`kinhin toolchains prune [--dry-run]`, and inspect size/selections with `kinhin toolchains`.
Pruning the cache touches only the regenerable host cache — never baked images or running VMs.
(Derived images are pruned separately, by `max_project_images`.)

```yaml
# config.yaml
toolchain_cache:
  auto_prune: true # sweep after each bake + daily while the fleet runs (default true)
  max_age_days: 30 # entries unused this long are deleted, 0 = never (default 30)
  max_gb: 50 # LRU eviction beyond this size, 0 = unlimited (default 50)
max_project_images: 8 # cap on derived images, LRU-evicted (default 8)
```

### Bundlers are project dependencies

Turbopack, Vite, Next.js, and other bundlers are **project dependencies** — they come
from `node_modules` via `npm ci` in your workflow and are never installed into the
image. What the toolchain guarantees is the base: node, `corepack enable` (so a
project's `packageManager` field picks pnpm/yarn), and warm package caches for every
package manager.
