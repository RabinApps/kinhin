# Toolchains & the shared cache

How to get Go, Node, Xcode, Flutter and friends onto kinhin runners, and how to cache their downloads.

[← Back to README](../README.md)

Every job runs on a fresh clone of an image, so anything a job installs is thrown away with the VM. There are three
ways to get tools onto a runner:

| Approach | Best for | How |
| --- | --- | --- |
| [Base image](#bake-tools-into-the-base-image) | Tools every job on this Mac needs | A provision script run by `kinhin image prepare` |
| [Per project](#per-project-toolchains) | Different repos needing different versions | `.kinhin.yml` in the repo, or `projects:` in `config.yaml`. kinhin bakes an image per project. |
| [Per job](#per-job-toolchains) | Tools only some workflows need, and all Linux container runtimes | `kinhin-toolchain install` in a workflow step |

Per-job installs also work with the usual `actions/setup-go`, `actions/setup-java` and friends, at the cost of
downloading the toolchain in every job. The [shared cache](#the-shared-download-cache) removes most of that cost.

## Bake tools into the base image

`kinhin image prepare` can run **your provision script** inside the VM once, after the runner agents are installed.
Every runner then boots with whatever the script installed. The script runs as the `admin` user, and a failure aborts
the prepare and leaves the previous image intact.

```bash
#!/bin/bash
# ~/kinhin/provision.sh
brew install wget cmake
mise install go@1.23.4 rust@1.82 java@temurin-21   # exact versions; mise ships in the base image
go version && rustc --version && java -version      # output is logged in `kinhin logs` as an audit trail
```

Wire it up with a flag (wins) or the config key:

```bash
kinhin image prepare --provision-script ~/kinhin/provision.sh
```

```yaml
# config.yaml
provision_script: "~/kinhin/provision.sh"
```

- **The script is your version pin.** Every prepare rebuilds from the pristine upstream image, so edit the script and
  re-run prepare to change toolchains. Homebrew and mise are both in the base image.
- **Need full Xcode?** Don't install it from a script (tens of GB). Point `image:` (or `image prepare --source`) at
  Cirrus Labs' `macos-tahoe-xcode:16` or `macos-runner:tahoe` images instead.
- The script has its own 30-minute budget. A configured script that is missing or empty fails the setup checklist
  before a long prepare starts.

## Per-project toolchains

Declare what a project needs and kinhin installs, pins and verifies it. Each distinct set is baked into its own
**derived image** (Tart only), so repos with different versions never interfere. Toolchains are always per project;
there is no global list.

You can declare them in two places:

```yaml
# config.yaml: you choose
projects:
  - pattern: "acme/api"                  # owner/name, or owner/* for every repo of an owner
    toolchains:
      specs: ["go@1.23.4", "node@22", "uv"]
      brew: ["wget", "cmake"]
      stacks: ["flutter@3.24.0"]
```

```yaml
# .kinhin.yml at the repo root: the repo chooses (needs repo_file: true on its projects: entry)
toolchains:
  specs: ["go@1.23.4", "node@22", "pnpm"]
```

Jobs from a repo with neither run on the plain base image.

### The `.kinhin.yml` file

kinhin reads the file **at the ref the job runs at**, so a `release/1.x` branch can pin `go@1.22.5` while `main` pins
`go@1.23.4`. The file is opt-in: it is ignored unless the matching `projects:` entry sets `repo_file: true`. It is
deliberately limited, because it is untrusted input that decides what gets installed on your Mac:

- Only a `toolchains:` section with `specs` and `stacks` is accepted. No `brew`, `provision_script`, `base_image` or
  cache settings.
- Every spec must be in the [curated catalog](#the-catalog). Unknown mise backends (`ubi:`, `npm:`, `cargo:`) are
  rejected. (Specs in `config.yaml` may fall through to mise.)
- The file is capped at 16 KB. A missing, invalid or oversize file is logged, shown in Diagnostics, and treated as
  absent. It never blocks the fleet.
- Fork pull requests never use the repo file. See [Security](security.md#per-project-toolchains).

GitHub, Gitea/Forgejo and GitLab supply the ref and the file. Buildkite, Bitbucket and Azure DevOps don't, so their
jobs use only `projects:` toolchains.

### Generating toolchains

`kinhin toolchains detect` scans a local checkout and writes the `toolchains:` block for you, with the evidence behind
every pick.

```bash
kinhin toolchains detect                  # scan the current directory
kinhin toolchains detect ~/code/acme-web  # or another checkout
kinhin toolchains detect --write          # write <path>/.kinhin.yml (refuses to overwrite)
kinhin toolchains detect --write --force  # overwrite an existing file
kinhin toolchains detect --json           # machine-readable result only
```

**stdout carries the `.kinhin.yml` block**, so it pipes cleanly. The evidence table and anything kinhin couldn't map go
to **stderr**. For a Node repo with a pnpm lockfile and TypeScript:

```text
$ kinhin toolchains detect ~/code/acme-web > .kinhin.yml
  node@20       .nvmrc: .nvmrc pins node v22.1.0
  node@20       package.json: engines.node >=20
  playwright    .github/workflows/ci.yml: runs `playwright`
  pnpm@9.1.0    package.json: packageManager pnpm@9.1.0
  typescript    package.json: depends on typescript
not in the catalog (skipped): husky

$ cat .kinhin.yml
toolchains:
  specs: ["node@20", "pnpm@9.1.0", "playwright", "typescript"]
```

Paste the same block under a `projects:` entry in `config.yaml` if you'd rather not commit a repo file.

`--json` prints only `{ specs, stacks, evidence, unmatched, recommendations }`. `--write` saves the block as `<path>/.kinhin.yml` and
refuses to replace an existing file unless you add `--force`.

**What it reads:**

- **Version files:** `.tool-versions`, `mise.toml`, `.nvmrc`, `.node-version`, `.python-version`, `.ruby-version`,
  `.go-version`, `.java-version`.
- **Manifests and lockfiles:** `package.json` (`engines`, `packageManager`, `devDependencies`), npm/pnpm/yarn/bun
  lockfiles, `go.mod`, `Cargo.toml`, `rust-toolchain`, `pyproject.toml`, `requirements.txt`, `uv.lock`, `Gemfile`,
  fastlane, `pubspec.yaml`, `Package.swift`, Gradle and Maven files, `composer.json`, `.csproj`, `global.json`,
  `mix.exs`, `deno.json`, `Dockerfile`, `CMakeLists.txt`, `Justfile`, `Taskfile`, `*.tf`, `Chart.yaml`, Expo and React
  Native projects, `vercel.json`, `wrangler.toml`.
- **GitHub Actions:** `.github/workflows/*` `setup-*` actions and known CLIs called in `run:` lines.

**Precedence.** For a version, a version file beats a manifest, a manifest beats a workflow, and a workflow beats the
catalog's default spec. Ranges are reduced to their floor: the major version for node, java, bun and deno (`^20.1` and `>=20` both become `20`), major.minor for the rest (`>=3.11,<4` becomes `3.11`).

**Always valid.** Runtimes are added automatically where the catalog requires them (pnpm or `vercel` pull in `node`;
`kotlin` or `gradle` pull in `java`), so the output satisfies the [no-implicit-installs rule](#rules-that-apply-to-every-declaration).
Only [catalog](#the-catalog) tools and stacks are emitted; anything else is listed as unmatched, because a repo file
cannot use `npm:` or `ubi:` specs. The block is checked by the same loader the engine uses and stays within the 16 KB
cap, so kinhin never emits YAML it would reject.

**Xcode and Swift.** Full Xcode is too large to install from a script, so it is never a toolchain. When the scan sees an
`.xcodeproj` or `.xcworkspace` (also under `ios/` and `macos/`), a `.xcode-version`, a `Package.swift` that targets iOS,
tvOS, watchOS or visionOS, or a workflow that calls `xcodebuild`, it prints a **recommendation** (stderr, and the
`recommendations` field in `--json`) to set `base_image:` (or `image prepare --source`) to an image that includes Xcode,
such as `ghcr.io/cirruslabs/macos-tahoe-xcode:latest`, and leaves `swift` out of the block because Xcode ships its own.
A plain Swift package (macOS-only or no Apple-platform targets, built with `swift build`) gets the `swift` toolchain
instead and no recommendation.

**Limits.** It scans a local directory only (no remote repos), reads GitHub Actions workflows only (no GitLab or Gitea
CI files), and doesn't edit `projects:` entries in `config.yaml`. The result is a starting point: review it, and remember
the file is only honored when the `projects:` entry sets `repo_file: true`.

### Resolution order

For each job, the first level that yields toolchains wins:

1. The repo's `.kinhin.yml` at the job's ref (only if `repo_file: true`).
2. The matching `projects:` entry's own `toolchains:`.
3. Nothing: the plain base image.

### The `projects:` keys

| Key           | Meaning |
| ------------- | ------- |
| `pattern`     | Required. `owner/name` or `owner/*`, case-insensitive, unique. |
| `repo_file`   | Honor the repo's `.kinhin.yml` (default `false`). |
| `toolchains`  | `specs`, `brew` and `stacks` for matching repos with no usable `.kinhin.yml`. |
| `share_cache` | Mount the [shared download cache](#the-shared-download-cache) for this project (default `false`; always off for fork PRs). |

Changes to `projects:` apply to a running fleet without a restart.

### Rules that apply to every declaration

- **Nothing is installed implicitly.** A stack that needs a runtime (`vercel` needs node) is a validation error that
  names the fix, until you list the runtime too.
- **Verification is the audit trail.** Each tool carries a verify command (`go version`, `flutter --version`, …). A
  bake aborts with the previous image intact if a check fails.
- **Deploy credentials stay per job.** Pass `VERCEL_TOKEN` and cloud credentials with workflow `env:`; they are never
  baked into an image.
- Versions may only contain `A-Z a-z 0-9 . _ + -`.

### The catalog

Run `kinhin toolchains` for the full list. Everything installs on macOS and Linux images unless noted.

- **Languages & runtimes:** node, go, rust, python, ruby, java, bun, deno, uv, zig, erlang, elixir, kotlin, scala,
  clojure, dart, swift, lua, julia, php, dotnet. (kotlin, scala and clojure need `java` selected too.)
- **JavaScript tools** (need node): pnpm, yarn, playwright, cypress, netlify-cli, firebase-tools, typescript, eslint,
  prettier, turbo, nx.
- **Build & quality:** cmake, ninja, maven, gradle, sbt, just, task, jq, yq, direnv, shellcheck, hadolint, yamllint,
  composer, fastlane.
- **Cloud & DevOps:** terraform, opentofu, kubectl, helm, kustomize, k9s, pulumi, packer, vault, gh, awscli, gcloud,
  flyctl, supabase.

**Stacks** bundle several pieces:

- `flutter[@version]`: Flutter SDK (default `stable`), plus fvm and CocoaPods on macOS. On Linux it builds web and
  Linux desktop out of the box; Android needs `java` and an Android SDK you provide, and iOS needs macOS.
- `expo[@version]`: `eas-cli` (needs node).
- `react-native`: watchman, CocoaPods and JDK 17 (macOS). Add node yourself if you build JS.
- `vercel[@version]` and `cloudflare[@version]`: the `vercel` and `wrangler` CLIs (need node).

### Derived images

- **Naming.** Derived images are named `<base image>-p<8 hex>`. Two repos that resolve to the same set share one image.
  Rebuilding the base image changes the digest, so derived images are rebaked.
- **Baking.** `kinhin image prepare --project owner/name [--ref X]` bakes one ahead of time. Otherwise the first job
  that needs a set starts the bake, and that job (and any queued behind it) runs on the base image until it's ready.
- **Pruning.** The number of derived images is capped by `max_project_images` (default 8) with least-recently-used
  eviction. `kinhin toolchains prune` and `kinhin cleanup` remove them too. The base image and running VMs are never
  touched.
- **Disk.** A derived image is a copy-on-write clone, so it costs roughly the toolchain itself: a few GB, and 5 GB or
  more for Flutter. `tart list` and `du` over-report because they count shared blocks once per image.
- **Linux runtimes.** apple/container and Docker get no derived images; use [per-job installs](#per-job-toolchains).

Useful commands:

```bash
kinhin toolchains --project owner/name [--ref main]     # what a repo resolves to
kinhin image prepare --project owner/name [--ref main]  # bake its image now
kinhin toolchains list-images                           # derived images: size, last used
kinhin toolchains prune [--dry-run]
```

The app's **Advanced → Toolchains** tab shows the same information read-only: your `projects:` rules with their
images (size, last used, delete, rebuild), the catalog, and copyable `.kinhin.yml` examples.

## Per-job toolchains

Every prepared image carries `kinhin-toolchain`, a helper that installs catalog tools from a workflow step. It is the
only way to get toolchains on the apple/container and Docker runtimes.

```yaml
jobs:
  web:
    runs-on: [self-hosted, kinhin]
    steps:
      - run: kinhin-toolchain install node@22 pnpm playwright
      - uses: actions/checkout@v4
      - run: pnpm install && pnpm test
```

- It runs the same install and verify steps as a bake, so a failed install fails the step. Unknown ids fall through to
  `mise use --global`.
- Later steps see the tools: new `PATH` entries go to `$GITHUB_PATH` and `$GITHUB_ENV` (GitHub and Gitea runners).
- Runtimes install first. A tool whose runtime you didn't list fails with the command to fix it.
- Pair it with `share_cache: true` so repeat installs are mostly cache hits.
- `kinhin-toolchain list` shows the available ids. `kinhin toolchains helper [--linux]` prints the helper for audit.

Bundlers like Vite, Next.js and Turbopack are project dependencies: they come from `node_modules` via `npm ci`, not
from the image. The image provides node, `corepack enable` (so `packageManager` picks pnpm or yarn), and warm package
caches.

## The shared download cache

A host-side cache at `~/Library/Application Support/Kinhin/toolchain-cache/` lets repeated bakes and installs skip
re-downloading mise tools, Homebrew bottles, npm packages, Flutter SDKs, Go modules, Gradle, NuGet and browsers.
Turn it on per project:

```yaml
projects:
  - pattern: "acme/api"
    share_cache: true
```

The cache is mounted into that project's bakes and runners, in a subdirectory scoped to the project. It is off by
default and always off for fork PRs. On Linux container runtimes it is bind-mounted at `/var/kinhin-cache`.

> **Don't enable it for untrusted code.** The cache is writable and holds things later jobs _execute_ (Cargo's `bin/`,
> Flutter SDKs, Playwright browsers, Gradle init scripts). A fork PR could plant a binary there that a later job runs,
> and the next bake could carry it into an image. Per-project subdirectories keep repos from poisoning each other, but
> leave `share_cache` off on a fleet that runs outside contributors' PRs.

### Expiry and pruning

The cache expires entries unused for 30 days and evicts least-recently-used entries beyond 50 GB. A one-hour grace
window means a prune never races a live download. Pruning only touches this regenerable cache, never images or running
VMs.

```yaml
# config.yaml
toolchain_cache:
  auto_prune: true   # after each bake, and daily while the fleet runs (default true)
  max_age_days: 30   # 0 = never expire (default 30)
  max_gb: 50         # 0 = unlimited (default 50)
max_project_images: 8
```

Sweep by hand with `kinhin toolchains prune [--dry-run]`. `kinhin doctor` reports the cache size and each project's
share state.
