# Runtimes & routing

Where jobs run (Tart VMs, apple/container microVMs, Docker containers, or directly on your Mac) and how one fleet routes
each job between them.

[← Back to README](../README.md)

> **Beta:** only the Tart runtime has been run for real. apple/container, Docker and host mode are covered by unit tests
> against fakes and have not been exercised live.

| Runtime             | Runs                                                         | Isolation                                    |
| ------------------- | ------------------------------------------------------------ | -------------------------------------------- |
| **Tart**            | macOS jobs, or Linux jobs on a [Linux base](#tart-linux-vms) | One VM per runner (linked clone)             |
| **apple/container** | Linux jobs                                                   | One lightweight microVM per runner container |
| **Docker**          | Linux jobs                                                   | Containers in your provider's shared VM      |
| **Host**            | Jobs on the Mac itself                                       | None. Opt-in, trusted repos only.            |

Each runner is bound to the image its job resolved to: the base image, or a derived image for the project's
[toolchains](toolchains.md#per-project-toolchains). Neither Linux container runtime bakes toolchains; jobs install them
with [`kinhin-toolchain install`](toolchains.md#per-job-toolchains).

## macOS (Tart)

### Choosing the base image

`image prepare` clones a Cirrus Labs macOS image by default and bakes the runner agents into it. To start from another
published image (`macos-sequoia-base`, `macos-sonoma-xcode`, …), set the top-level `base_image:` or pick one in the app's
macOS card, then press **Rebuild image…** in that card: a changed base image only takes effect once the image is rebuilt (the
Apple container and Docker rows have a **Build image…** button for their Linux images). `kinhin doctor` flags a reference that is neither a published image nor a local VM, so a typo doesn't
surface as a failed clone mid-prepare.

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
the macOS card: each entry has its own base-image picker (including the Xcode images), a status line, **Prepare** /
**Rebuild…** and **Remove**, and **Add image** creates a new one. Rebuilding an image only discards the per-project
images derived from that image.

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

Manage routes in **Advanced → Routing** (pools with a live health chip, a budget slider per runtime, labels, and routes)
or with `kinhin runtimes route add|remove`. `kinhin runtimes` prints the same summary. Changes edit only the relevant
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
