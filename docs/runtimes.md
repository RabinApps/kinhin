# Runtimes & routing

Where jobs run (Tart VMs, apple/container microVMs, Docker containers, or directly on your Mac) and how one fleet routes
each job between them.

[← Back to README](../README.md)

> **Beta:** Tart (macOS VMs) and apple/container have been run for real, and Docker has run real Gitea jobs (the
> [end-to-end suite](e2e-testing.md)). Tart Linux VMs and host mode are covered by unit tests against fakes and have not
> been exercised live.

| Runtime             | Runs                                                         | Isolation                                    |
| ------------------- | ------------------------------------------------------------ | -------------------------------------------- |
| **Tart**            | macOS jobs, or Linux jobs on a [Linux base](#tart-linux-vms) | One VM per runner (linked clone)             |
| **apple/container** | Linux jobs                                                   | One lightweight microVM per runner container |
| **Docker**          | Linux jobs                                                   | Containers in your provider's shared VM      |
| **Host**            | Jobs on the Mac itself                                       | None. Opt-in, trusted repos only.            |

Each runner is bound to the image its job resolved to: the base image, or a derived image for the project's
[toolchains](toolchains.md#per-project-toolchains). Neither Linux container runtime bakes toolchains; jobs install them
with [`kinhin-toolchain install`](toolchains.md#per-job-toolchains). Every baked Linux image (Apple container, Docker and
a [tart Linux VM](#tart-linux-vms)) carries `git` and `jq` next to the runner agents — what `actions/checkout`,
`git ls-files` and JSON-piping workflow steps expect on any CI host; an image baked by an older build gains them only
after a re-bake (`kinhin image prepare --container`, `--docker`, or `--source <name>` for a tart Linux VM).

## macOS (Tart)

### Choosing the base image

`image prepare` clones a Cirrus Labs macOS image by default and bakes the runner agents into it. To start from another
published image (`macos-sequoia-base`, `macos-sonoma-xcode`, …), set the top-level `base_image:` or pick one in the app's
macOS card, then press **Rebuild image…** in that card: a changed base image only takes effect once the image is rebuilt (the
Apple container and Docker rows have a **Build image…** button for their Linux images). `kinhin doctor` flags a reference that is neither a published image nor a local VM, so a typo doesn't
surface as a failed clone mid-prepare.

`kinhin image prepare` automates a clone-boot-inject sequence and skips the download when tart or the image already
exists. By hand, the first two steps are `tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest tahoe-base` and
`tart run tahoe-base`; the runner agent is then injected over SSH. Point `image:` at the result (`tahoe-base`).

### Multiple macOS images

Besides the main `image:`, you can keep extra named images, each baked on its own base, for example one on a Cirrus
`-xcode` image for jobs that need full Xcode:

```yaml
image: "tahoe-base"
images:
  - name: xcode
    base_image: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"
```

Build them with `kinhin image prepare --image xcode`, or `kinhin image prepare --all` to build `image:` and every
`images:` entry one after another (each bake is disk-heavy). A `--source` or `--target` names one image, so it cannot be
combined with `--all`; `--runner-version` pins the runner agents in every baked image. In the app, use **More images** in
the macOS card (**Advanced → Capacity**): each entry has its own base-image picker (including the Xcode images), a
status line, **Prepare** / **Rebuild…** and **Remove**, and **Add image** creates a new one. The block stays available
when tart's primary base image is a Linux one — a mixed macOS + Linux fleet is built from named images. Rebuilding an
image only discards the per-project images derived from that image.

Names must be letters, numbers, `.`, `_` or `-`, differ from `image:` and from each other, and must not start with
`kinhin-` or `orchard-`: those names are how kinhin recognises runner VMs, so it would clean them up. Removing an entry
leaves its prepared VM on disk (`tart delete <name>`).

#### Choosing the image per job

Give an entry `labels:` and a workflow picks it with `runs-on`, next to your usual labels:

```yaml
images:
  - name: xcode
    base_image: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"
    labels: [xcode]
```

```yaml
jobs:
  build:
    runs-on: [self-hosted, macos, arm64, xcode] # runs on the xcode image
```

Jobs that ask for none of the extra labels run on `image:`. A runner cloned from an extra image registers with the fleet
labels plus the image's labels. Notes:

- Image labels must include at least one label that is not already in the fleet `labels:`, and two images cannot share
  the same labels. If a job requests the labels of several images, the one with the most labels wins.
- Prepare the image first. A job for an image that was never prepared cannot clone it and shows a clone error.
- A runner with extra labels can also pick up a plain job, because the forge only checks that a runner has every label
  the job asks for. Plain jobs are still counted against the main image.
- Label selection works for GitHub and Buildkite. Other forges register runners with the fleet labels only, so their jobs
  always run on `image:`.
- Per-project toolchain images (`projects:`) are derived from `image:` only, so a job routed to an extra image does not
  get one.
- Changing `images:` restarts the fleet's engine; running VMs are kept.

For reproducible bakes, pin the image to a digest. A `:latest` tag can be republished at any time, and `kinhin doctor`
warns about mutable tags:

```bash
kinhin image digest ghcr.io/cirruslabs/macos-sequoia-base:latest
#   ghcr.io/cirruslabs/macos-sequoia-base:latest@sha256:…
#   pin it: base_image: "ghcr.io/cirruslabs/macos-sequoia-base:latest@sha256:…"
```

A pin never moves on its own: re-run `image digest` and re-prepare to update it.

### Cancelling a build

A bake can take a long time, and you can stop it at any point: press **Ctrl-C** in `kinhin image prepare`, or the
**Cancel** button next to the busy line in the app (the macOS card, the setup wizard and the Toolchains tab's rebuild
all have one). The command exits with code 130.

Cancelling is safe by construction:

- The bake works in a temporary scratch VM (or scratch container for the Linux runtimes) named
  `kinhin-prepare-tmp-<timestamp>`. A cancelled bake stops it and deletes it, even when the cancel lands mid-download or
  mid-install.
- The previous image is only replaced in the final commit, which cancellation cannot interrupt. A cancelled bake always
  leaves the image that was there before untouched — the app says so next to the busy line.

What is kept, on purpose: the downloaded base image in tart's registry cache (the expensive part — the next bake starts
from it), toolchain downloads written through the shared cache, and Docker's/container's own build cache. `kinhin
image prepare` also sweeps up `kinhin-prepare-tmp-*` VMs left by an earlier crashed bake before it starts, and
`kinhin cleanup --vms` lists and removes them as "image-build scratch VMs".

### Seeing and removing installed images

`kinhin image list` shows every image kinhin can find on this Mac, per runtime: the tart base image and any `images:`
entries (role, size), derived per-project images (size, last used), and the apple-container/Docker images. Each
runtime section opens with a count and total disk usage — image bloat at a glance — and the `--json` document carries
the same totals under `totalGB`, keyed by runtime. The diagnostics surface carries them too: `kinhin doctor --json`
reports the per-runtime totals under `imageTotalGB`, and plain `kinhin doctor` prints them as a single `images:` row.
It also
lists what is configured but not built yet, says why a runtime could not be listed, and marks the images runners are
using right now. A machine with a busy Docker daemon is the reason `--runtime` exists: it narrows the listing — and
the probes behind it — to one runtime, so only what you asked about is touched.

```bash
kinhin image list              # installed images, per runtime
kinhin image list --runtime docker       # just the Docker images (tart, container: same idea)
kinhin image list --json       # the same inventory as a document
kinhin image delete <name>     # report only: what would go, and how to re-bake it
kinhin image delete <name> --yes
kinhin image prune             # one pass: stale records + unused local images (report only)
kinhin image prune --yes
```

Deletion follows `kinhin cleanup`'s contract: without `--yes` nothing is touched, and an image that runners are using
is refused until you `kinhin stop` (a runner VM or a leftover bake scratch VM is refused outright — those belong to
`kinhin cleanup --vms`). Deleting a derived image also clears its index entry, and deleting a configured image means
`kinhin image prepare` again before the fleet can run from it.

`kinhin image prune` is the whole-machine sweep in one confirmed pass: it clears every stale derived-image record
(the index remembers an image tart no longer has) and deletes the local images nothing uses. Configured images, every
`base_image:`, and anything a runner is using are never candidates — in-use images are listed as kept and the rest of
the sweep proceeds without them. A runtime whose images could not be listed is skipped and said so, never swept blind.

You don't have to remember that, though: when unused images are wasting disk, `kinhin doctor` says so — a `prune:` row
under its `images:` row with the count, the reclaimable space and the command, the app's Diagnostics tab shows the
same line, and `kinhin doctor --json` carries it under `imagePrune` (the selection is the prune plan's own, so the
doctor never offers a sweep the command would refuse).

### Isolating runner VMs from each other

By default Tart puts every VM on one shared network, so a job can reach other runner VMs and your LAN. If jobs can
include code you don't fully trust (fork PRs, outside contributors), turn on Softnet:

```yaml
tart_softnet: true # boots runner VMs with `tart run --net-softnet`
```

Each VM can then reach the internet but not its neighbours or your local network. Softnet needs a one-time setup:

```bash
brew install openai/tools/softnet
sudo chown root "$(readlink -f "$(which softnet)")" && sudo chmod u+s "$(readlink -f "$(which softnet)")"
```

Repeat the `chown`/`chmod` after `brew upgrade softnet`. (A passwordless-sudo rule for the resolved binary path also
works.) kinhin refuses to start with `tart_softnet: true` if `softnet` isn't installed, rather than silently using the
shared network. Baked images also disable SSH password login; re-run `kinhin image prepare` to apply that to an existing
image.

### Pointing kinhin at a custom tart binary

`config.yaml` may name the exact tart binary kinhin runs — for a tart installed outside the usual directories, or
when several tarts coexist on one Mac:

```yaml
tart_path: "/opt/tart/bin/tart"
```

`tart_path:` is **authoritative for the whole app**: the CLI (`kinhin image prepare`, `kinhin toolchains`,
`kinhin cleanup`, the orphaned-VM scan in `kinhin status`), the daemon's fleet, `kinhin doctor`, the setup
checklist, and the app's probes (This Mac, Toolchains, Runtimes health) all run that exact binary — never a
different tart found on PATH.

- A configured path that is not executable reads as **not installed everywhere**, even when `which tart` finds one:
  the override is a decision, not a hint, and kinhin never falls back behind your back. The This Mac card says why
  — `not installed — tart_path: /opt/tart/bin/tart does not exist` — and `kinhin doctor` reports tart NOT FOUND
  until the path is fixed.
- Leave `tart_path:` unset and kinhin searches its fixed trusted directories first (`/opt/homebrew/bin`,
  `/usr/local/bin`, `/usr/bin`, …) and then `PATH`, so a writable directory a job or shell profile put early on
  `PATH` cannot shadow `tart`.
- Every tart action goes through the same binary — VM boots, `tart list`, the GB sizes in the Toolchains tab and
  `kinhin toolchains list-images` — so a probe and the action it describes can never disagree about which tart
  you have.

## Choosing a Linux runtime

Linux jobs can run three ways:

|                       | **Tart Linux VM**                                  | **apple/container**                 | **Docker**                               |
| --------------------- | -------------------------------------------------- | ----------------------------------- | ---------------------------------------- |
| One instance is       | A full Linux VM (linked clone)                     | A container in its own microVM      | A container in your provider's shared VM |
| Isolation             | Own kernel, disk and network                       | Own kernel per container            | Shared kernel with every other slot      |
| Density               | Lowest (bounded by VM shapes)                      | High                                | Highest (bounded by `max_slots`)         |
| Disk per instance     | 50 GB planning default (`disk_gb`)                 | 8 GB                                | 8 GB                                     |
| amd64                 | No                                                 | No                                  | Yes, emulated                            |
| Needs                 | Only tart                                          | The `container` CLI and its service | Docker Desktop, OrbStack or colima       |
| Mixes with macOS jobs | Yes — a tart fleet can serve macOS and Linux VMs together when using named images with distinct labels | Yes                                 | Yes                                      |
| Best for              | Full control: your distro, system services, `sudo` | The default for Linux CI            | Teams already running Docker             |

- **Starting fresh?** Use **apple/container**: VM-grade isolation, no daemon, and it shares a fleet with macOS VMs.
- **Already run Docker Desktop, OrbStack or colima?** Use **Docker**.
- **Need a specific distro, kernel modules or long `sudo` provisioning?** Use a **Tart Linux VM**.

Container runners register with opt-in labels (`kinhin-container`, `kinhin-docker`), so a workflow can pick a pool with
`runs-on:` while the config routes the rest.

### apple/container

```yaml
container:
  image: "kinhin-ci-linux" # built by: kinhin image prepare --container --target kinhin-ci-linux
  base_image: "ubuntu:24.04" # optional: any Debian/Ubuntu-based image
  cpus: 4
  memory_gb: 8
```

Install the CLI with `brew install container && container system start`, then run `kinhin image prepare --container`.
Once `container:` is configured, the setup checklist and `kinhin doctor` gain container rows with one-click fixes.
`kinhin runtimes` (or **Advanced → Routing**) shows the pool, its cap and its health.

### Docker

```yaml
docker:
  image: "ghcr.io/acme/kinhin-ci-linux" # built by: kinhin image prepare --docker --target <name>
  base_image: "ubuntu:24.04" # optional: any Debian/Ubuntu-based image
  cpus: 2
  memory_gb: 4
  max_slots: 8 # hard cap on concurrent container slots
  platform: "linux/arm64" # default; "linux/amd64" runs under emulation
```

kinhin never starts or configures your Docker provider; it only runs containers in it. Run
`kinhin image prepare --docker` to bake the agents. Docker slots register with `kinhin-docker`, so jobs opt in with
`runs-on: [kinhin-docker]`.

Prefer a CI-built image? Write a Dockerfile that installs the GitHub Actions runner at `/opt/actions-runner` (with an
executable `config.sh`) and the Gitea runner at `/opt/gitea-runner/gitea-runner`, push it, and set `docker.image:`. Bake
any toolchains into it yourself; kinhin bakes none for Docker.

**amd64 runs under emulation** (Rosetta if enabled in Docker Desktop, otherwise QEMU). Expect slower jobs, and some
software (JITs, certain Go/Java/.NET builds) fails under emulation. Prefer arm64 unless a job needs x86_64. amd64 slots
register with an `x64` label instead of `arm64`, and you must rebuild the image after changing `platform`.

### Tart Linux VMs

Choose **Tart (Linux VM)** under **This Mac → Linux jobs** in the app, or point `base_image:` at a Linux VM. A tart
fleet can serve macOS and Linux VMs at the same time when you use named images with distinct labels — each VM clones
from its own image and advertises only the labels that image is configured with. To make a Linux base VM:

```bash
# from a published image (pick from the menu, or pass --from <ref>)
kinhin image prepare --linux --target <name> --from
# or from an install ISO: creates a bare VM; you install the OS by hand in its window
kinhin image prepare --linux --target <name> --iso <arm64.iso>
# then bake the runner agents into it
kinhin image prepare --source <name>
```

Guests need an apt-based distro with passwordless `sudo` (the published Cirrus Labs images have both). macOS-only
toolchain entries (Homebrew, CocoaPods) are skipped on Linux guests.

#### Mixing macOS and Linux Tart VMs in one fleet

Give each named image its own distinct labels so jobs select the right OS. A Linux-named image's runners strip the
fleet's `macos` label automatically, so they will not attract macOS jobs:

```yaml
image: "tahoe-base"
labels: [self-hosted, macos, arm64]
images:
  - name: xcode
    base_image: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"
    labels: [xcode]
  - name: linux
    base_image: "ghcr.io/cirruslabs/ubuntu:latest"
    labels: [linux]
```

Jobs that ask for `[self-hosted, macos, arm64]` run on `image:` (macOS VMs); jobs that ask for `[self-hosted, linux]`
run on the `linux` image (Linux VMs). The fleet `labels:` may still include `macos` — you do not need to remove it.

## How usage is measured

The app and `kinhin status` show live CPU and RAM per instance (see
[Live CPU and RAM usage](app.md#live-cpu-and-ram-usage)). Each runtime is read from the host side:

| Runtime              | Source                                   | CPU                                        | RAM                             |
| -------------------- | ---------------------------------------- | ------------------------------------------ | ------------------------------- |
| **Tart** (macOS, Linux VMs) | `ps` on the VM's `tart run` process | Percent of one core, from the change in CPU time between samples (can exceed 100%) | Resident memory of that process, against the configured `vm.memory_gb` |
| **Docker**           | `docker stats --no-stream`               | Percent of one core                        | Used / limit                    |
| **apple/container**  | `container stats`                        | Not shown (the CLI only exposes a cumulative counter) | Used / limit         |

For tart these are the host's view of the VM process, not metrics from inside the guest. CPU appears from the second
sample. Samples are cached for about 2 seconds, so several readers (the app, the CLI) share one stats command. Only
active instances are measured.

## Per-repo and per-workflow routing

One fleet can mix runtimes. Add a `runtimes:` section to route by repo, and override per workflow with labels:

```yaml
runtimes:
  default: tart # repos with no route
  budget: { tart: 0.6, appleContainer: 0.4 } # host-budget split; can never overcommit
  routes:
    - pattern: "acme/ios-app" # whole repo → Tart VMs
      runtime: tart
    - pattern: "acme/api" # whole repo → Linux containers
      runtime: appleContainer
    - pattern: "acme/web@Nightly" # one workflow → containers
      runtime: appleContainer
```

Precedence: **workflow route → repo route → `runs-on:` label → default**. Capacity is split by the `budget` weights, and
`kinhin status` shows the result. If a split would leave a configured route with zero capacity, the app warns you
before you can save it.

Manage routes in **Advanced → Routing** (pools with a live health chip, routes, the default pool, and labels) or with
`kinhin runtimes route add|remove`. The capacity split lives in **Advanced → Capacity**: a budget slider per runtime —
drag it or type a percent, and lock a pool to keep its share fixed while the others rebalance. `kinhin runtimes` prints the same summary. Changes edit only the relevant
part of `config.yaml`, must pass full validation, and reach a running fleet without a restart.

## Route one workflow with the CLI

`kinhin workflow route` moves a single workflow's jobs to a runtime without hand-editing YAML:

```bash
kinhin workflow route ".github/workflows/deploy.yml" appleContainer  # or just the workflow name: "Deploy"
kinhin workflow route ci.yml docker --job build # one job
kinhin workflow route ci.yml tart --dry-run --json # plan only, machine-readable
```

It:

- rewrites each job's `runs-on:` **comment-preservingly** — appending the pool's marker (`kinhin-container`,
  `kinhin-docker`, `kinhin-host`), replacing GitHub-hosted labels the fleet's runners can never satisfy with the
  target pool's exact labels, and stripping stale markers when targeting tart (tart is markerless);
- **reconciles the config route only when precedence requires it** — a repo route that outranks the marker, or a
  markerless target off the default — through the same validated editor `runtimes route add` uses; a running
  daemon reloads it live;
- refuses what it can't safely edit (<code v-pre>${{ … }}</code> expressions, `{group:, labels:}` mappings, reusable-workflow jobs)
  and points at `kinhin runtimes route add <owner/repo>@<Workflow> <runtime>` for those;
- refuses a runtime whose pool isn't configured, printing its setup commands and [the comparison above](#choosing-a-linux-runtime).

`--consent` is required for `host`, and `kinhin runtimes --json` reports the per-runtime `availability` sweep
(`ready` / `missing:<tool>` / `broken:<reason>`), so scripts can pick a runtime this Mac can actually run.

## Windows (not available as a local runtime on Mac)

Windows CI jobs cannot run locally on a Mac through kinhin's container runtimes, and **Windows containers are not an option on macOS at all**.

- **`microsoft/windows` / `mcr.microsoft.com/windows` are Windows Server containers.** They share the Windows NT kernel with the host and need a Windows host kernel (and, for process isolation, a matching host build). Docker Desktop on macOS runs a Linux VM and has no Windows container mode, so it cannot pull or run these images. There is no way to switch Docker Desktop on a Mac into Windows-container mode.
- **"Windows in a container" projects (e.g. `dockur/windows`) are not Windows containers.** They are full VMs (QEMU/KVM) packaged to run inside a Linux Docker container, using `/dev/kvm` from the Linux host. Docker Desktop on macOS does not expose `/dev/kvm` to containers, and Apple's `container` CLI is a microVM runtime — not a KVM host — so neither can run these. Macs also have no Linux KVM to pass down in the first place. Even where KVM is available, the result is a full Windows VM, not a lightweight Windows container.

**If you need Windows CI on a Mac fleet, the realistic local path is a Windows VM on Apple Silicon**, driven by kinhin as a fleet runtime — see [Windows VMs on Apple Silicon](https://github.com/RabinApps/kinhin/blob/main/docs/plans/windows-vms-apple-silicon.md). That plan is substrate-probed and not yet implemented; the gating question is a bootable Windows ARM guest source (Parallels template/ISO, or a scripted hypervisor backend) and the per-forge Windows runner install/registration story.

**If you do not need to run Windows locally**, route Windows jobs to GitHub-hosted Windows runners instead. GitHub Actions now has Windows ARM64 hosted runners (`windows-11-arm` label, public repositories) and standard Windows hosted runners — add the appropriate `runs-on` label and kinhin's fleet (macOS + Linux) stays where it is.


## Host mode: run jobs directly on your Mac

Host mode runs a job as an ephemeral runner process **on your Mac itself**: no VM, no container. It's fast and sees
your real toolchains, but has **no isolation**: the job runs with your user's privileges and can read your files and
reach your network. Use it only for repositories you fully trust, never a public repo that accepts pull requests from
strangers.

It is opt-in per route and needs explicit consent:

```yaml
runtimes:
  default: tart # `default: host` is rejected; host is never a fallback
  routes:
    - pattern: "acme/scripts"
      runtime: host
      consent: true # required for host routes
```

- **Consent is enforced everywhere.** Config validation, `kinhin runtimes route add <pattern> host --consent`, and the
  app's Add Route sheet all refuse without it. Host routes show an _unisolated_ warning in the route list.
- **Install the agent once.** Run `kinhin setup repair host-agent` (or use the one-click fix in the setup checklist). The
  runners are installed, SHA-256 verified, under `~/Library/Application Support/Kinhin/host-runner`.
- **Workflows can opt in** with `runs-on: [kinhin-host]`. Only opted-in workflows can ever land on your Mac.
- **The machine isn't reset between jobs.** Each runner is ephemeral and gets a work directory that is scrubbed
  afterwards, but anything a job installs outside it persists.
- Host routes work for GitHub, Gitea and Forgejo.
