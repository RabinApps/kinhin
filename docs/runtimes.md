# Runtimes & routing

Where jobs execute: Tart VMs, Apple `container` microVMs, Docker containers, or directly on your
Mac — and how one fleet routes each job between them.

[← Back to README](../README.md)

> **Beta:** only the Tart runtime has been run for real. apple/container, Docker and host mode are covered by
> unit tests against fakes and have not been exercised live.

Every job is placed on a **Runtime** — a pluggable executor that provisions instances, runs the
agent, and tears down. Four backends ship:

| Runtime             | Runs                                                                               | Isolation                                    |
| ------------------- | ---------------------------------------------------------------------------------- | -------------------------------------------- |
| **Tart**            | macOS jobs — or Linux jobs on a Linux base (see [Tart Linux VMs](#tart-linux-vms)) | One VM per runner (linked clone)             |
| **apple/container** | Linux jobs                                                                         | One lightweight microVM per runner container |
| **Docker**          | Linux jobs                                                                         | Containers in your provider's shared VM      |
| **Host**            | Jobs on the Mac                                                                    | None — opt-in, trusted repos only            |

The engine is runtime-agnostic — pools, capacity partitioning, and routing all live above the
protocol, so new backends slot in without touching lifecycle code.

So Linux jobs have **three** execution options — two container runtimes plus a full VM on Tart.
[Choosing a Linux runtime](#choosing-a-linux-runtime) compares them side by side.

Both Linux runtimes support [managed toolchains and the shared cache](toolchains.md#linux-runtimes):
`image prepare --container|--docker` bakes the config's `toolchains:` into the Linux image, and
`share_cache: true` mounts the host cache into every runner container at `/var/kinhin-cache`.

### Choosing the macOS base image

`image prepare` clones a pre-configured Cirrus Labs macOS image by default and bakes the runner
agents into it. Set the top-level `base_image:` to start from a different published image instead
(`ghcr.io/cirruslabs/macos-sequoia-base:latest`, `…/macos-sonoma-xcode:latest`, … — pick one in the
app's macOS card) or at a local VM you made with `image prepare --linux --target <name>`
(`--from <ref>` starts that Linux VM from a pre-configured image too). Absent key = the default
macOS base. `kinhin doctor` and the setup checklist flag a reference that is neither a
pre-configured image nor a local VM — otherwise a typo here would only surface as a mid-prepare
clone failure.

For reproducible bakes, pin the reference to a digest: every bake then uses the exact same
bits, while a `:latest` tag (including the curated defaults) can be republished by the registry
at any time — doctor and the checklist warn about mutable tags with the command to fix it:

```bash
kinhin image digest ghcr.io/cirruslabs/macos-sequoia-base:latest
#   ghcr.io/cirruslabs/macos-sequoia-base:latest@sha256:…
#   pin it: base_image: "ghcr.io/cirruslabs/macos-sequoia-base:latest@sha256:…"
```

Bump the pin deliberately (re-run `image digest`, re-prepare) — a pin never moves on its own.

### Isolating runner VMs from each other

By default Tart puts every VM on one shared virtual network, so a job in one runner VM can reach
the other runner VMs and anything else on your LAN. If jobs can include code you don't fully
trust (fork PRs, outside contributors), turn on Softnet isolation:

```yaml
tart_softnet: true # boots runner VMs with `tart run --net-softnet`
```

Each VM can then reach the internet but not its neighbours or the local network. It needs the
`softnet` binary and its one-time privilege setup — install it with
`brew install cirruslabs/tools/softnet`, then give it root once. Softnet cannot start without it
(`tart run` fails with "root privileges are required to run and passwordless sudo was not
available", or the VM boots with no reachable IP). Either make the real binary setuid root:

```bash
sudo chown root "$(readlink -f "$(which softnet)")" && sudo chmod u+s "$(readlink -f "$(which softnet)")"
```

or add a passwordless-sudo rule for it (`%admin ALL = (root) NOPASSWD: <softnet path>` in
`/etc/sudoers.d/softnet`, mode 440). Use the resolved path, not the Homebrew symlink, and redo the
setuid step after `brew upgrade softnet`, which replaces the binary. kinhin refuses to
start with `tart_softnet: true` when `softnet` isn't installed, rather than silently booting VMs
on the shared network. Baked images also disable SSH password login (`image prepare` writes
`/etc/ssh/sshd_config.d/000-kinhin-hardening.conf`), so a VM that can reach another still can't
log in with the base image's default `admin` password; re-run `kinhin image prepare` to pick
that up on an existing image.

## Choosing a Linux runtime

Linux jobs can run three ways, and which one fits depends on the isolation, density, and setup
overhead you want:

|                          | **Tart Linux VM**                                                                                                                                 | **apple/container**                                                | **Docker**                                                                       |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| What one instance is     | A full Linux VM, linked clone of your prepared image                                                                                              | A container in its own lightweight microVM                         | A container in your provider's shared Linux VM                                   |
| Isolation                | VM-grade: own kernel, own disk, own network stack                                                                                                 | MicroVM-grade: own kernel per container                            | Container-grade: shared kernel with every other slot and anything else in the VM |
| Concurrency              | Bounded by VM shapes (like macOS VMs) — the heaviest option per job                                                                               | High — microVMs are small and boot fast                            | Highest — small container slots, bounded by daemon resources and `max_slots`     |
| Per-instance disk        | 50 GB planning default (`disk_gb` overrides)                                                                                                      | 8 GB planning default                                              | 8 GB planning default                                                            |
| amd64 / emulation        | Native arm64 only (Tart is arm64)                                                                                                                 | Native arm64 only (`container.platform` is rejected)               | arm64 native; `linux/amd64` under Rosetta/QEMU emulation                         |
| Extra software           | None — tart itself, which macOS jobs need anyway                                                                                                  | The container CLI + its system service                             | A running Docker provider (Docker Desktop, OrbStack, colima)                     |
| Image bakes & toolchains | `image prepare --linux` bakes the same agents and managed toolchains                                                                              | `image prepare --container`                                        | `image prepare --docker`, or a CI-built Dockerfile                               |
| Shared download cache    | Mounted over virtiofs (like macOS guests) when `share_cache: true`                                                                                | Mounted at `/var/kinhin-cache` when `share_cache: true`            | Mounted at `/var/kinhin-cache` when `share_cache: true`                          |
| Mixing with macOS jobs   | No — a tart fleet serves one OS at a time (the base image decides)                                                                                | Yes, alongside Tart macOS VMs, with a budget split                 | Yes, alongside Tart macOS VMs, with a budget split                               |
| Best for                 | Full VM control: apt-based distro of your choice, kernel modules, system services, sudo scripts — or a Linux-only Mac with tart already installed | The default for Linux CI: strong isolation without a Docker daemon | Teams already running a Docker provider; CI-built images pushed to a registry    |

Rules of thumb:

- **Starting fresh with Linux CI?** Use **apple/container** — real VM isolation, no daemon to
  babysit, and it coexists with macOS Tart VMs in one fleet.
- **Already run Docker Desktop / OrbStack / colima?** Use **Docker** — one more image instead of
  one more runtime, and `max_slots` caps the cost per job.
- **Need things a container can't give you** (a specific distro with system services, kernel
  modules, nested virtualization, long `sudo` provisioning)? Use a **Tart Linux VM** — it is a
  real machine your jobs control end to end.
- **Mac that never runs macOS jobs?** All three work; with tart already installed the Tart Linux
  VM needs no further installs (but remember: its pool is the tart pool, so it can't serve macOS
  jobs without re-preparing a macOS base image).

Both container runtimes register their runners with opt-in labels (`kinhin-container`,
`kinhin-docker`), so a workflow can pick a pool with `runs-on:` while the config routes the rest.

## Tart Linux VMs

Tart clones Linux VMs as happily as macOS ones, and kinhin can serve Linux jobs from a full Tart
VM when you want VM-grade isolation for Linux work without a container runtime. In the app, the
**Tart (Linux VM)** checkbox under **This Mac → Linux jobs** sets the tart `base_image` to a Linux
image for you (it needs tart installed); a tart fleet serves one OS at a time, so remove `macos`
from `labels:` when you turn it on. Two ways to get a Linux base VM:

- **From a pre-configured image** — `kinhin image prepare --linux --target <name> --from` shows
  the curated menu (`ghcr.io/cirruslabs/ubuntu:latest`, `ghcr.io/cirruslabs/debian:latest`, … —
  all of them ship the `admin`/`admin` credentials and trust Tart's SSH key, so the bake works
  out of the box); `--from <ref>` clones any other tart reference. The published images already
  have an OS, so no install step is needed.
- **From an install ISO** — `kinhin image prepare --linux --target <name> --iso <arm64.iso>`
  creates a bare VM (`tart create --linux`) and boots it once with the ISO attached as a second
  disk; you install the OS by hand in the VM window (create an `admin` user and let Tart's SSH
  key in). A failed boot rolls the half-created VM back.

Either way, the VM ends up on disk under its `<name>` — then
`kinhin image prepare --source <name>` runs the usual agent bake against it (the registry pull is skipped for local names), and
pointing `base_image: <name>` at it makes every runner VM a clone of it. The bake injects the
same token-gated agents and managed toolchains as on macOS, picking the right ones for the guest.
The bake detects the guest OS (`uname -s` in the scratch VM) and installs `linux-arm64` agent
binaries for every forge in the same `$HOME` layout as macOS, so runner registration is
identical. Linux guests need an apt-based distro with passwordless `sudo` (the curated images
have both). With `toolchains.share_cache` on, Linux guests mount the host cache over virtiofs
themselves at `/var/kinhin-cache` (macOS guests get it automatically); macOS-only toolchain
entries (Homebrew formulas, CocoaPods, …) are skipped on a Linux guest. The apple/container and
Docker runtimes remain the lighter-weight options for Linux jobs — see
[Choosing a Linux runtime](#choosing-a-linux-runtime) for the full comparison.

## Apple `container` (Linux microVMs)

kinhin can run Linux jobs in [apple/container](https://github.com/apple/container) microVMs: one
lightweight VM per runner container on Apple silicon, no Docker daemon, and stronger isolation than
a shared Docker VM. Add this to your config and run `kinhin image prepare --container` to bake the
agents into a Linux image:

```yaml
container:
  image: "kinhin-ci-linux" # built by: kinhin image prepare --container --target kinhin-ci-linux
  base_image: "ubuntu:24.04" # optional: what that image is built on (any Debian/Ubuntu-based image)
  cpus: 4
  memory_gb: 8
```

Requires the container CLI (`brew install container && container system start`). macOS jobs still
need Tart — containers run Linux workloads only. When `container:` is configured, the setup
checklist and `kinhin doctor` gain container rows (CLI health, system-service state, image present)
with one-click fix actions; without it, the rows never appear. Run `kinhin runtimes` (or the app's
**Advanced → Routing** tab) to see the pool, its cap, and its live health once configured.

## Docker (Linux containers)

Linux runner containers inside your provider's shared Linux VM (Docker Desktop, OrbStack, or
colima): one container per job slot with per-slot `--cpus`/`--memory` limits, registration over
`docker exec` (no SSH, no guest IP), and the daemon teardown as soon as the job is done. kinhin
delegates the VM — it never starts, stops, or configures the provider. Add this to your config and
run `kinhin image prepare --docker` to bake the agents into a Linux image:

```yaml
docker:
  image: "ghcr.io/acme/kinhin-ci-linux" # built by: kinhin image prepare --docker --target <name>
  base_image: "ubuntu:24.04" # optional: what that image is built on (any Debian/Ubuntu-based image)
  cpus: 2
  memory_gb: 4
  max_slots: 8 # hard cap on concurrent container slots
  platform: "linux/arm64" # default and native; "linux/amd64" runs x86_64 under emulation (see below)
```

When `docker:` is configured, the checklist and `kinhin doctor` gain Docker rows (daemon reachable,
image present) exactly like the container rows; without it, they never appear. Docker slots
register with a `kinhin-docker` label so jobs opt in via `runs-on: [kinhin-docker]`, and
`max_slots` clamps the budget partition.

### Architecture and emulation

kinhin runs on Apple Silicon, so Docker runner containers are `linux/arm64` by default (native
speed). If a workflow needs x86_64, set `docker.platform: "linux/amd64"` (or pick it in the app
under This Mac → Linux jobs, or bake once with `kinhin image prepare --docker --platform linux/amd64`).
Disclosure: **`linux/amd64` runs under emulation** — Rosetta if you enabled it in Docker Desktop,
otherwise QEMU. Expect slower jobs (QEMU can be several times slower), and some software fails
under emulation: JITs, certain Go/Java/.NET builds, and anything using unsupported CPU
instructions. Prefer arm64 unless a job needs x86_64. Emulation is provided by your Docker
provider; kinhin does not configure it. Details:

- The baked agents follow the platform (`actions-runner-linux-x64` / `gitea-runner-linux-amd64`), so rebuild the image after changing `platform` — the checklist and `kinhin doctor` flag an image whose architecture doesn't match, and a rebuild never reuses an image of the other architecture as its base.
- amd64 Docker slots register with an `x64` label instead of `arm64`, so `runs-on: [kinhin-docker, x64]` selects them and `arm64` jobs never land on emulated slots.
- Apple `container` is arm64-only (`container.platform` is rejected). Toolchains are architecture-neutral.
- kinhin warns whenever amd64 is selected: on `image prepare`, in the checklist / `kinhin doctor`, in the app, and once at fleet start.

### Choosing the base image

`image prepare --container|--docker` bakes the agents on top of a base image: `ubuntu:24.04` by
default. Pick another in the app (Advanced → Toolchains → Rebuild images, or the Linux card in
Setup) or set `base_image:` under `container:` / `docker:`; `--container-image` / `--docker-image`
override it for one run. The install scripts use `apt-get`, so the base must be Debian- or
Ubuntu-based (an Alpine or Fedora base is rejected up front with a clear message).

### Building the Docker image with a Dockerfile (CI-friendly)

`kinhin image prepare --docker` bakes the image on the spot — fine for a one-host setup, but it needs a stored token and a live daemon on the machine doing the baking. For a reproducible, CI-buildable image, use a Dockerfile instead: it lands the runner agents at exactly the paths the registration scripts expect (`/opt/actions-runner` with `config.sh`, `/opt/gitea-runner/gitea-runner`), performs the same downloads `image prepare` would, and can be built anywhere with a `linux/arm64` builder (Apple silicon hosts run arm64 containers natively — keep the platform pinned unless you set `docker.platform: "linux/amd64"`, in which case build with `--platform linux/amd64`; the Dockerfile picks the matching agent from `TARGETARCH`):

```dockerfile
# kinhin-ci-linux — kinhin runner agents on Linux (arm64 native; amd64 runs emulated)
# docker build --platform linux/arm64 -t ghcr.io/acme/kinhin-ci-linux:latest .
FROM ubuntu:24.04

ARG TARGETARCH  # set by BuildKit: arm64 or amd64

ARG RUNNER_VERSION=2.325.0      # pin to a github/actions/runner release
ARG GITEA_RUNNER_VERSION=3.5.0  # pin to a gitea/runner release

# GitHub Actions agent at /opt/actions-runner (config.sh must be executable there)
RUN GH_ARCH=$([ "$TARGETARCH" = "amd64" ] && echo x64 || echo arm64) \
 && mkdir -p /opt/actions-runner \
 && cd /opt/actions-runner \
 && curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${GH_ARCH}-${RUNNER_VERSION}.tar.gz" | tar xz \
 && ./bin/installdependencies.sh || echo "warning: installdependencies.sh reported issues"

# Gitea runner at /opt/gitea-runner/gitea-runner
RUN mkdir -p /opt/gitea-runner \
 && cd /opt/gitea-runner \
 && curl -fsSL "https://gitea.com/gitea/runner/releases/download/v${GITEA_RUNNER_VERSION}/gitea-runner-${GITEA_RUNNER_VERSION}-linux-${TARGETARCH}.xz" -o runner.xz \
 && xz -d runner.xz && chmod +x runner && mv runner gitea-runner \
 && ./gitea-runner --version
```

Build and push from CI (any linux/arm64 runner — or amd64 with QEMU; use `--platform linux/amd64` for an x86_64 image):

```bash
docker build --platform linux/arm64 -t ghcr.io/acme/kinhin-ci-linux:latest .
docker push ghcr.io/acme/kinhin-ci-linux:latest
```

Then point `docker.image:` at the pushed reference. Bake your toolchains into the image the same way (`toolchains:` via a provision script in the Dockerfile) — a CI-built image has no access to the host cache during its build, so anything the jobs need must live in the image (runners on your own host still get the shared-cache mount at runtime when `share_cache: true`). Unlike `image prepare`, the Dockerfile bakes both agents unconditionally; that's harmless, since agents only register when your fleet has a stored token for their platform. Pin the `ARG`s to a release (the versions above match kinhin's current pinned fallbacks) and bump them deliberately.

## Per-repo & per-workflow runtime routing

One fleet can mix runtimes: macOS repos on Tart VMs, Linux repos in Apple containers. Add a `runtimes:` section to route per repo — and override per **workflow** (or per job) with labels:

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

Routing precedence: **workflow route → repo route → `runs-on:` label → default**. Container runners always register with a `kinhin-container` label (plus optional `container.labels`), and Docker slots with `kinhin-docker`, so any job can opt into a Linux pool with `runs-on: [kinhin-container]` or `runs-on: [kinhin-docker]` without touching kinhin's config. No route and no label → the `runtimes.default` pool. Capacity is partitioned by the `budget` weights — the tightest density that can still never overcommit your Mac — and `kinhin status` reports `capacityByRuntime` so the split is visible. If a split starves a configured route (its runtime's cap hits 0), the pane warns you before you can save it.

Routes can also be managed from the terminal with `kinhin runtimes route add|remove` (see [Commands](../README.md#commands)).

### The Routing pane

The app's **Advanced → Routing** tab shows the pools with their per-runtime caps and budget shares, plus every route (repo and workflow). Each pool card carries a **live health chip** (● ready / ● missing / ● error) from the runtime's own probe — tart launch check, `container system status`, `docker info` — with the fix hint shown alongside any problem.

- The **Budget** card edits the split directly: a slider per non-default runtime (the default keeps the remainder), a default-runtime picker, a **live cap preview** per row ("3 inst" updates as you drag), and a warning strip when the split on screen would starve a configured route with a cap of zero.
- The **Labels** card edits the fleet's base label set and `container.labels` (commit on Enter or focus loss; empty label lists are rejected, and the `kinhin-container` routing marker is always merged in at pool build).
- Routes can be added and removed in place.

Every change rewrites only the relevant section of `config.yaml` — comments elsewhere are preserved — and lands only if the updated file still passes the engine's full config validation; all of it reaches a running fleet live via `reload_config` (budget weights re-partition capacity, label edits rebuild the forges' demand query — no restart). Prefer the terminal? `kinhin runtimes` prints the same pools/caps/budget/routes/health summary.

## Host mode: run jobs directly on your Mac

Host mode is the fourth runtime: a job runs as an **ephemeral GitHub runner process on your Mac itself** — no VM and no container. It is fast (nothing boots) and sees your real toolchains, but it has **no isolation at all**: the job runs with your user's privileges and can read and modify your files and reach your network. Use it only for repositories and workflows you fully trust (your own private scripts, never a public repo that accepts pull requests from strangers).

Because of that, host mode is opt-in per route and needs explicit consent:

```yaml
runtimes:
  default: tart # `default: host` is rejected — host is never a fallback
  routes:
    - pattern: "acme/scripts" # whole repo → runs on this Mac, unisolated
      runtime: host
      consent: true # required for host routes (and rejected on other runtimes)
```

- **Consent is enforced everywhere.** Config validation rejects a host route without `consent: true`. `kinhin runtimes route add <pattern> host --consent` refuses to run without the flag. In the app, **Advanced → Routing → Add Route…** lists "Host — this Mac, no isolation" and won't add the route until you tick the consent checkbox; host routes show a ⚠︎ _unisolated_ marker in the route list.
- **Install the agent once.** Host runs use the GitHub actions-runner and the Gitea runner (which also serves Forgejo), installed — with SHA-256 verification — under `~/Library/Application Support/Kinhin/host-runner`. When a host route exists, the setup checklist and `kinhin doctor` gain a _Host runner agent_ row with a one-click **Install Host Runner Agent** fix; from the terminal run `kinhin setup repair host-agent`. Without host routes, none of this appears.
- **Explicit `runs-on` marker.** The host pool always registers with the `kinhin-host` label, so a workflow can also opt in with `runs-on: [kinhin-host]` and only opted-in workflows can ever land on your Mac.
- **Ephemeral process, warm machine.** Each runner registers with `--ephemeral`, gets its own work directory under kinhin's support directory, and that directory is scrubbed when the runner is torn down. The Mac itself is not reset between jobs, so anything a job installs or leaves outside its work directory persists.
- **Every forge.** Host routes work for GitHub, Gitea and Forgejo. Gitea-family runners have no `--ephemeral`, so kinhin watches the runner go idle after its job (the same watch it uses for VMs), then stops the daemon and scrubs the work directory. Gitea host runners always register with `:host` labels (your configured labels are forced to the host scheme, plus `kinhin-host:host`), so a job can never be picked up in a container by mistake.
- `kinhin runtimes` shows the Host pool and its health (agent installed or not) alongside the others; `kinhin doctor --json` includes a `hostRuntime` section (state, routed patterns, and the unisolated warning) only when a host route exists.
