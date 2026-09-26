# Toolchains & the shared cache

How to get Go, Node, Xcode, Flutter and friends onto kinhin runners: bake them into the image,
let kinhin manage them, or install them per job, and share one download cache across all of it.

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

Instead of writing a provision script, declare the runtimes you want and let kinhin
install, pin, and verify them during `kinhin image prepare`:

```yaml
# config.yaml
toolchains:
  specs:
    [
      "go@1.23.4",
      "node@22",
      "bun@1.1.27",
      "deno@2",
      "java@temurin-17",
      "dotnet",
      "uv",
    ]
  brew: ["wget", "cmake", "yamllint"]
  stacks: ["flutter@3.24.0", "expo", "react-native", "vercel", "cloudflare"]
  share_cache: false
  cache:
    auto_prune: true # sweep after each prepare + daily while the fleet runs
    max_age_days: 30 # entries unused this long are deleted (0 = never)
    max_gb: 50 # LRU eviction beyond this size (0 = unlimited)
```

- **Nothing is installed implicitly.** Every entry installs exactly its own pieces. A
  stack that needs a runtime (e.g. `vercel` needs node) is a **validation error naming
  the fix** ("add `node@22` to toolchains.specs") until you select that runtime too.
- **The catalog is advisory.** Unknown specs pass through to mise and unknown brew
  entries to brew — so the long tail (`ghc`, `perl`, …) works with zero kinhin code.
  Run `kinhin toolchains` to see the curated list.
- **Verification is the audit trail.** Each tool/stack carries a verify command
  (`go version`, `dotnet --list-sdks`, `flutter --version`…); the prepare aborts
  with the old image intact if any check fails, and the version prints land in
  `kinhin logs`.
- **Deploy auth stays per-job.** `VERCEL_TOKEN`, `CLOUDFLARE_API_TOKEN`, and cloud
  credentials are passed via workflow `env:` — never baked into an image.

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

## Per-job toolchains

Baking suits tools every job needs. For tools only some workflows need, keep
`toolchains:` lean and let each workflow install what it needs. Every prepared
image (Tart, apple/container, and Docker) carries `kinhin-toolchain`, a helper
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
- **Pair it with `share_cache: true`.** Otherwise every job downloads from
  scratch. With the host cache mounted, a repeat install is mostly a cache hit.
- **Versions are validated.** Only `[A-Za-z0-9._+-]` is accepted, and an
  installer that ignores versions (brew, apt) rejects `@version` instead of
  silently dropping it.
- Audit what gets baked with `kinhin toolchains helper [--linux]`.

## The shared download cache

`image prepare` always mounts a host-side cache —
`~/Library/Application Support/kinhin/toolchain-cache/` — into the scratch VM, so
repeated prepares skip re-downloading mise tools, brew bottles, npm packages, and
Flutter SDKs. Every ecosystem gets its own env redirect at install time:

| Ecosystem               | Envs pointed at the cache                                                                |
| ----------------------- | ---------------------------------------------------------------------------------------- |
| mise / Homebrew         | `MISE_CACHE_DIR`, `HOMEBREW_CACHE`                                                       |
| npm / pnpm / yarn / bun | `NPM_CONFIG_CACHE`, `npm_config_store_dir`, `YARN_CACHE_FOLDER`, `BUN_INSTALL_CACHE_DIR` |
| Flutter (fvm, macOS)    | `FVM_CACHE_PATH`                                                                         |
| Go / Rust               | `GOMODCACHE` + `GOCACHE`, `CARGO_HOME`                                                   |
| Python                  | `UV_CACHE_DIR`, `PIP_CACHE_DIR`                                                          |
| JVM                     | `GRADLE_USER_HOME`                                                                       |
| .NET                    | `NUGET_PACKAGES`                                                                         |
| e2e browsers            | `PLAYWRIGHT_BROWSERS_PATH`, `CYPRESS_CACHE_FOLDER`                                       |

Set **`share_cache: true`** to mount the same cache into every runner VM: per-job
installs — `npm ci`, `pnpm install`, `mise install`, `fvm install`, `dotnet restore`,
`playwright install` — then hit warm cache instead of re-downloading gigabytes per job.
This is best-effort and off by default: the tools tolerate concurrent VM writers (worst
case a duplicate download), but it does share cache state across ephemeral jobs.

### Linux runtimes

Both Linux runtimes ([Apple `container` and Docker](runtimes.md)) are covered too:
`image prepare --container` and `image prepare --docker` bind-mount the same host cache into
their scratch containers (`-v host:guest`), bake the config's `toolchains:` with a
Linux-specific script (apt for dotnet, mise bootstrapped on demand, npm globals; macOS-only
entries like brew tools, fvm, and CocoaPods are skipped with a note — override per prepare
with `--linux-toolchain`/`--linux-stack`), and with `share_cache: true` every Linux runner
container gets the same `-v` mount plus the guarded cache-env exports in its registration
script — pointing at the container-side path `/var/kinhin-cache`. macOS-only and
cross-platform selections resolve independently per platform, so a mixed fleet shares one
host cache without cross-contaminating guests. `kinhin doctor` reports the cache's size and
per-ecosystem breakdown (human output and the `toolchainCache` section of `--json`).

### Expiry and pruning

The cache auto-expires — default 30 days since last use, with LRU eviction past 50 GB —
and a one-hour grace window means a prune can never race a live download. Tune or
disable it under `toolchains.cache`, sweep manually with
`kinhin toolchains prune [--dry-run]`, and inspect size/selections with `kinhin toolchains`.
Pruning touches only the regenerable host cache — never baked images or running VMs.

### Bundlers are project dependencies

Turbopack, Vite, Next.js, and other bundlers are **project dependencies** — they come
from `node_modules` via `npm ci` in your workflow and are never installed into the
image. What the toolchain guarantees is the base: node, `corepack enable` (so a
project's `packageManager` field picks pnpm/yarn), and warm package caches for every
package manager.
