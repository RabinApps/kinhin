# Runtimes & routing

Every job is placed on a **Runtime** — a pluggable executor that provisions instances, runs the
agent, and tears down. Three backends ship:

| Runtime                | Runs       | Isolation                                                        |
| ---------------------- | ---------- | ---------------------------------------------------------------- |
| **Tart**               | macOS jobs (Linux jobs on a Linux base) | full VM per job (linked clone of a prepared base image) |
| **apple/container**    | Linux jobs | one lightweight microVM per runner container, no Docker daemon    |
| **Docker**             | Linux jobs | one container per job slot in your provider's shared Linux VM     |

The engine is runtime-agnostic — pools, capacity partitioning, and routing all live above the
protocol, so new backends slot in without touching lifecycle code.

## Per-repo & per-workflow routing

One fleet can mix runtimes. Add a `runtimes:` section to route per repo — and override per
**workflow** with labels:

```yaml
runtimes:
  default: tart # repos with no route
  budget: { tart: 0.6, appleContainer: 0.4 } # host-budget split (no overcommit by construction)
  routes:
    - pattern: "acme/ios-app" # whole repo → Tart VMs
      runtime: tart
    - pattern: "acme/api" # whole repo → Linux containers
      runtime: appleContainer
    - pattern: "acme/web@Nightly" # one workflow → containers
      runtime: appleContainer
```

Routing precedence: **workflow route → repo route → `runs-on:` label → default**. Container
runners always register with a `kinhin-container` label (plus optional `container.labels`),
so any job can opt into the Linux pool with `runs-on: [kinhin-container]` without touching
config.

## Tart Linux VMs

Tart clones Linux VMs as happily as macOS ones. `kinhin image prepare --linux --target <name>`
creates a Linux base VM two ways: `--from` clones a pre-configured image (the curated
`ghcr.io/cirruslabs/ubuntu` / `debian` / `fedora` images ship `admin`/`admin` and Tart's SSH
key, so no OS install is needed), and `--iso <arm64.iso>` attaches install media for a
hand-installed OS instead. Then `kinhin image prepare --source <name>` bakes the runner agents
(the registry pull is skipped for local VM names) and `base_image: <name>` makes every runner
VM a clone of it.

The bake detects the guest OS (`uname -s` in the scratch VM) and installs the matching agent
binaries for every forge: `linux-arm64` builds in the same `$HOME` layout as macOS, so runner
registration is identical. Linux guests need an apt-based distro with passwordless `sudo` (the
curated images have both). With `toolchains.share_cache` on, Linux guests mount the host cache
over virtiofs themselves (macOS guests get it automatically); macOS-only toolchain entries
(Homebrew formulas, CocoaPods, …) are skipped on a Linux guest. The apple/container and Docker
runtimes below remain the lighter-weight option for Linux jobs.

## apple/container for Linux jobs

One lightweight VM per runner container on Apple silicon — no Docker daemon, stronger
isolation than a shared Docker VM:

```yaml
container:
  image: "kinhin-ci-linux" # built by: kinhin image prepare --container --target kinhin-ci-linux
  cpus: 4
  memory_gb: 8
```

Requires the container CLI (`brew install container && container system start`).

## Docker for Linux jobs

Linux runner containers inside your provider's shared Linux VM (Docker Desktop, OrbStack, or
colima): one container per job slot with per-slot CPU/memory limits, registration over
`docker exec` (no SSH, no guest IP), and container teardown as soon as the job is done. kinhin
delegates the VM — it never starts, stops, or configures the provider:

```bash
kinhin image prepare --docker
```

### Architecture and emulation

Docker runner containers are `linux/arm64` by default: native on Apple Silicon. Set
`docker.platform: "linux/amd64"` (or bake with `kinhin image prepare --docker --platform linux/amd64`,
or use the picker under This Mac → Linux jobs) when a workflow needs x86_64.

::: warning linux/amd64 runs under emulation
Rosetta if enabled in Docker Desktop, otherwise QEMU. Expect slower jobs (QEMU can be several
times slower), and some software fails under emulation: JITs, certain Go/Java/.NET builds, and
anything using unsupported CPU instructions. Prefer arm64 unless a job needs x86_64. Emulation
is provided by your Docker provider; kinhin does not configure it.
:::

- Rebuild the image after changing `platform`. The checklist and `kinhin doctor` flag an image
  built for the other architecture.
- amd64 slots register with an `x64` label instead of `arm64`: use `runs-on: [kinhin-docker, x64]`.
- Apple `container` is arm64-only.

## Inspecting the split

`kinhin runtimes` (or the app's **Advanced → Routing** tab) shows the pools with their per-runtime
caps and budget shares, plus every route (repo and workflow). Each pool card carries a **live
health chip** (● ready / ● missing / ● error) from the runtime's own probe, and the tab's
**Budget** card edits the split directly with a live cap preview per row.
