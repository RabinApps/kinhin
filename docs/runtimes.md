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
macOS card. `kinhin doctor` flags a reference that is neither a published image nor a local VM, so a typo doesn't
surface as a failed clone mid-prepare.

For reproducible bakes, pin the image to a digest. A `:latest` tag can be republished at any time, and `kinhin doctor`
warns about mutable tags:

```bash
kinhin image digest ghcr.io/cirruslabs/macos-sequoia-base:latest
#   ghcr.io/cirruslabs/macos-sequoia-base:latest@sha256:…
#   pin it: base_image: "ghcr.io/cirruslabs/macos-sequoia-base:latest@sha256:…"
```

A pin never moves on its own: re-run `image digest` and re-prepare to update it.

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
| Mixes with macOS jobs | No (a tart fleet serves one OS at a time)          | Yes                                 | Yes                                      |
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
fleet serves one OS at a time, so remove `macos` from `labels:`. To make a Linux base VM:

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
