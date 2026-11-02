# Runtimes & routing

Where jobs run (Tart VMs, apple/container microVMs, Docker containers, or directly on your Mac) and how one fleet routes
each job between them.

[← Back to README](../README.md)

> **Beta:** every runtime has run real jobs from Gitea, Forgejo and GitLab CE in the
> [end-to-end suite](e2e-testing.md): Tart macOS and Linux VMs, apple/container, Docker and host mode. GitHub has run on
> Tart macOS and apple/container.

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
published image (`macos-golden-gate-base`, `macos-tahoe-xcode`, …), set the top-level `base_image:` or pick one in the app's
macOS card, then press **Rebuild image…** in that card: a changed base image only takes effect once the image is rebuilt (the
Apple container and Docker rows have a **Build image…** button for their Linux images). `kinhin doctor` flags a reference that is neither a published image, a digest pin of one, nor a local VM, so a typo doesn't
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
- Label selection works for GitHub. Other forges register runners with the fleet labels only, so their jobs
  always run on `image:`.
- Per-project toolchain images (`projects:`) are derived from `image:` only, so a job routed to an extra image does not
  get one.
- Changing `images:` restarts the fleet's engine; running VMs are kept.
- `warm_pool` on an entry keeps booted VMs of that image ready, so its jobs skip the clone and boot. See
  [warm pool](scaling.md#warm-pool). Warm VMs are not registered, so the forge does not list them.
- `min_idle` on an entry keeps that many runners of the image registered and idle, so the forge always lists one for
  its labels (`image_min_idle:` does the same for the top-level `image:`). See
  [Idle runners per pool and image](scaling.md#idle-runners-per-pool-and-image), including how this shares Apple's
  limit of two macOS VMs.

```yaml
images:
  - name: xcode
    base_image: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"
    labels: [xcode]
    warm_pool: 1
```

For reproducible bakes, pin the image to a digest. A `:latest` tag can be republished at any time, and `kinhin doctor`
warns about mutable tags:

```bash
kinhin image digest ghcr.io/cirruslabs/macos-sequoia-base:latest
#   ghcr.io/cirruslabs/macos-sequoia-base:latest@sha256:…
#   pin it: base_image: "ghcr.io/cirruslabs/macos-sequoia-base:latest@sha256:…"
```

A pin never moves on its own: re-run `image digest` and re-prepare to update it.

A digest pin also passes `kinhin doctor` beyond the curated list — any digest-pinned `ghcr.io/cirruslabs/macos-*`
reference is accepted, because the pin names exact bits that serve every bake even when the tag itself is later retired
from the registry.

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

|                       | **apple/container** (recommended)   | **Docker**                               | **Tart Linux VM**                                  |
| --------------------- | ----------------------------------- | ---------------------------------------- | -------------------------------------------------- |
| One instance is       | A container in its own microVM      | A container in your provider's shared VM | A full Linux VM (linked clone)                     |
| Isolation             | Own kernel per container            | Shared kernel with every other slot      | Own kernel, disk and network                       |
| Density               | High                                | Highest (bounded by `max_slots`)         | Lowest (bounded by VM shapes)                      |
| Disk per instance     | 8 GB                                | 8 GB                                     | 50 GB planning default (`disk_gb`)                 |
| amd64                 | Yes, under Rosetta (`platform`)     | Yes, emulated                            | No                                                 |
| Needs                 | The `container` CLI and its service | Docker Desktop, OrbStack or colima       | Only tart                                          |
| Mixes with macOS jobs | Yes                                 | Yes                                      | Yes — a tart fleet can serve macOS and Linux VMs together when using named images with distinct labels |
| Best for              | The default for Linux CI            | Teams already running Docker             | Full control: your distro, system services, `sudo` |

- **Starting fresh?** Use **apple/container**: VM-grade isolation, no daemon, and it shares a fleet with macOS VMs.
  Install it with `kinhin setup repair container`.
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
  docker: true # optional: Docker inside each runner container (see below)
  flags: ["--shm-size", "2g"] # optional: extra `container run` arguments
  platform: "linux/arm64" # default; "linux/amd64" runs x86_64 under Rosetta (see below)
```

Install it with `kinhin setup repair container`, or by hand with `brew install container` and
`container system start --enable-kernel-install` (the flag installs the default Linux kernel; without it `container run`
fails). Then run `kinhin image prepare --container`. [Full install steps](install.md#installing-a-linux-runtime).
Once `container:` is configured, the setup checklist and `kinhin doctor` gain container rows with one-click fixes.
`kinhin runtimes` (or **Advanced → Routing**) shows the pool, its cap and its health.

Container runners register with the fleet `labels:` plus `kinhin-container` and any `container.labels:` — but **not**
with the fleet's `macos` label, because these guests run Linux: a macOS job would never finish there. Set
`fleet_labels: false` under `container:` to drop the inherited fleet labels entirely (replace-not-add): the pool then
registers with `kinhin-container` and `container.labels:` alone. `min_idle: N` under `container:` keeps `N` container
runners registered and idle, so one is always listed for these labels, even while another runs a job (see
[Idle runners per pool and image](scaling.md#idle-runners-per-pool-and-image)).

#### Docker inside container runners

`docker: true` under `container:` gives every runner container its own Docker daemon, so jobs can run `docker run`,
`docker build` (with buildx), `docker compose`, published ports and networks. Each runner starts with every Linux
capability (`--cap-add ALL`), which dockerd needs for its iptables chains; before the runner registers, kinhin remounts
`/proc/sys` read-write (Apple container mounts it read-only, and dockerd writes `net.ipv4.ip_forward`), starts
`dockerd` in the background (log: `/var/log/dockerd.log` in the container) and waits up to 60 seconds for `docker info`
to answer. A runner whose daemon does not start fails registration with the end of that log. Jobs run as root, so no
`sudo` is needed. The daemon lives and dies with its runner container, so build cache is not shared between jobs;
images pulled from Docker Hub come through kinhin's [Docker Hub cache](#docker-hub-cache).

The image needs Docker: with `docker: true`, `kinhin image prepare --container` (and **Prepare** in the app) installs
`docker.io`, `iptables`, and `docker-buildx` and `docker-compose-v2` where the distribution has them, unless the base
image already has `dockerd`. Re-bake after turning it on. Every capability makes the container's root much closer to
root on its microVM; the microVM is still the isolation boundary, as without Docker.

##### Docker Hub cache

Every Docker runner starts with an empty Docker, so without help each job pulls its images (`services:` databases,
Docker actions, test images) from Docker Hub again, and every runner on the Mac counts against one IP's anonymous pull
limit. So with `docker: true`, kinhin runs a pull-through cache of Docker Hub and points each runner's dockerd at it:

- **The cache** is one Apple container, `registry-cache-kinhin`, running Docker's `registry:3` in proxy mode (1 vCPU,
  1 GB, entries kept 336 hours) with its data in `~/Library/Application Support/Kinhin/registry-cache/`. The first
  Docker runner that needs it starts it; a running cache is adopted as it is and a stopped one (after a reboot) is
  started again. It is not a runner: it takes no runner slot or capacity, recovery and the orphan sweep leave it
  alone, and `kinhin image prune` keeps `registry:3` while a pool uses the cache. Stop it with `container stop
  registry-cache-kinhin` and delete its data directory to empty it.
- **Each runner**: Apple container gives the cache a new address on every start and containers have no DNS names,
  so when a Docker runner registers, before dockerd starts, kinhin looks up the cache's current address, checks the
  runner can reach it (waiting up to 20 seconds for a cache that is still starting), and merges `"registry-mirrors":
  ["http://<address>:5000"]` into the image's `/etc/docker/daemon.json`. Every other setting in that file is kept;
  a mirror the image already lists is replaced.
- **If anything on that path fails** (the cache does not start, or takes more than 60 seconds to start because its
  first start may pull `registry:3`; the runner cannot reach it), the runner logs why and registers anyway, pulling
  straight from Docker Hub. A slow start goes on in the background for the next runners. An image whose daemon.json
  is not valid JSON is left as it is: dockerd fails on that file with or without the cache, and the runner does not
  register. The new daemon.json is written beside the old one and renamed over it, so a failed write leaves the image's
  file as it was. dockerd also falls back to Docker Hub by itself whenever the mirror stops answering.

It can be on by default, unlike the shared toolchain cache (`share_cache`), because jobs cannot write to it: a
pull-through cache only stores what Docker Hub serves, and Docker checks every layer against the digest it asked for,
so one job cannot plant an image for the next. Only Docker Hub images go through it; other registries (`ghcr.io`,
`quay.io`, …) are pulled directly. amd64 pools use it too (the cache stores every architecture an image has).

To keep Docker but skip the cache, give `docker:` a mapping: `docker: { cache: false }`, on `container:` or on one
pool. A pool that leaves `docker:` out inherits the section's whole value, cache setting included. `kinhin doctor`
shows whether the cache is running, its address and how much it holds.

#### Extra `container run` flags

`flags:` under `container:` appends arguments to the `container run` that starts each runner container, after kinhin's
own flags and before the image. Give each flag and each value as its own list element (`["--shm-size", "2g", "--dns",
"1.1.1.1"]`, or `"--shm-size=2g"`); they are passed as arguments, never through a shell. The loader rejects the flags
kinhin sets itself, in any spelling (`--name`, `--rm`, `--detach`/`-d`, `--cpus`/`-c`, `--memory`/`-m`, `--platform`,
`--arch`/`-a` (both come from `platform`), `--os`, plus `--help` and `--version`), empty elements, and a first element
that is not a flag. Run `container run --help` for what the rest do.

#### x86_64 (amd64) container runners

`platform: "linux/amd64"` under `container:` (or on one pool) runs x86_64 runner containers: kinhin starts them with
`container run --platform linux/amd64`, and Apple container runs their code under Rosetta for Linux. `kinhin image
prepare --container` bakes the image as amd64 (an amd64 scratch container from the base image, the x64 runner agents,
and the image tagged `linux/amd64`), so re-bake after changing `platform`, and give an amd64 pool an image of its own.
`--platform linux/amd64` on `kinhin image prepare --container` bakes for amd64 without changing the config.
If an amd64 container does not start on your Mac, install Rosetta with `softwareupdate --install-rosetta`.

An amd64 runner registers with `x64` in place of the fleet's `arm64` label, so `runs-on: [self-hosted, x64, linux]`
lands there and an `arm64` job never does. kinhin counts queued jobs that carry the fleet labels with `x64` in place of
`arm64` as demand, and a job that asks for `x64` goes to Apple container even when another runtime is the default.
Expect jobs to run slower than on arm64, and some software fails under Rosetta (JITs, certain Go/Java/.NET builds,
AVX-512). Prefer arm64 unless a job needs x86_64.

With `docker: true`, dockerd runs under Rosetta too, and its built-in builder cannot start a `RUN` step there
(`rosetta error: failed to open elf at -exec-root=/var/run/docker`: the network setup hook re-runs dockerd through
`/proc/<pid>/exe`, which is Rosetta). So once dockerd answers, kinhin creates a `docker-container` buildx builder
named `kinhin` (`default-load=true`, so built images land in the local store as usual) and selects it for every job
with `BUILDX_BUILDER=kinhin` in the runner's `.env` (and for login shells) and with a Docker context named `kinhin` on
the same local dockerd, which also reaches tools that run `docker build` with a cleaned environment. `docker build`
and `docker compose build` work unchanged; the first build on a runner also starts the builder's BuildKit container. A
job that switches back to the `default` builder hits the error again. The builder needs buildx 0.14 or later in the
image (Ubuntu 24.04's `docker-buildx` is 0.30; Debian 12 has none and Debian 13 has 0.13): without it the runner still
registers, and its log says builds will fail. `docker run`, `docker pull` and port mappings are unaffected.

#### Several container pools

`pools:` under `container:` splits Apple container into named pools, each with its own image, shape, labels, floor,
Docker, flags and platform. The keys at the top of `container:` are the defaults every pool inherits; a pool sets only what it
changes, plus an optional `max:` (at most that many of its runners at once):

```yaml
container:
  cpus: 2 # defaults for every pool
  memory_gb: 7
  docker: true
  pools:
    linux: { image: kinhin-ci-linux, labels: [linux], min_idle: 1 }
    big:
      image: kinhin-ci-linux
      labels: [linux, big]
      cpus: 4
      memory_gb: 12
      flags: ["--shm-size", "2g"]
      max: 2
    linux-x64: { image: kinhin-ci-linux-x64, labels: [linux], platform: linux/amd64 }
```

- **Routing.** A job routed to Apple container (by a route, the `kinhin-container` label or the default runtime) lands
  in the pool whose labels it carries, the most specific one when several match, the same rule as
  [named Tart images](#choosing-the-image-per-job): `runs-on: [self-hosted, arm64, linux, big]` goes to `big`, `[...,
  linux]` to `linux`. A job no pool's labels claim goes to the **default pool**: the one with the fewest labels (a pool
  without labels catches everything else), then the first by name. Each pool's runners also register with
  `kinhin-container-<name>`, which targets that pool alone and routes the job to Apple container even without a route;
  `kinhin workflow route FILE appleContainer --pool NAME` adds it for you. A job that asks for `x64` or `arm64` only
  lands in a pool of that architecture (`[self-hosted, x64, linux]` goes to `linux-x64` above, `[self-hosted, arm64,
  linux]` to `linux`); when the default pool runs the other one, the same rule picks among the pools of the job's. On a
  [GitHub scale set](forges/github.md#scale-set-mode-in-kinhin), each pool gets its own set, `kinhin-container-<name>`.
- **Capacity.** The pools share Apple container's budget: its `runtimes.budget` share in a mixed fleet, else the Mac
  minus `reserve:`. A runner starts only if its pool's `cpus` and `memory_gb` fit in what the running containers (each
  at its own pool's size) leave of it, and the pool is under its `max:`. When the pool a job needs is full, kinhin does
  not start another pool's runner for it (that runner's labels could not take the job). A pool larger than the whole
  budget never starts: `kinhin doctor` and the log say so.
- **Floors.** Each pool's `min_idle` is its own (the top-level one is only their default), and an idle runner of one
  pool never counts for another's jobs (see [Idle runners per pool and image](scaling.md#idle-runners-per-pool-and-image)).
- **Images.** `kinhin image prepare --container --pool NAME` bakes one pool's image on its `base_image`;
  `--container --all` bakes every pool's image, each shared image once. A shared image gets Docker when any pool that
  runs it has `docker: true` (dockerd only starts in the pools that ask for it), and two pools sharing an image must
  name the same `base_image` and `platform`. `kinhin image prune` keeps every pool's image. A pool whose image is not built yet is
  left out (logged once, and `kinhin doctor` says so): its jobs wait and its `min_idle` is skipped, instead of failed
  starts holding every pool back. kinhin rechecks the local images every minute, so a pool starts within a minute of
  its bake.
- **Restarts.** Each instance remembers its pool. One adopted without a record, or from a pool you since removed, runs
  as the default pool.
- **In the app.** **Advanced → Routing** has a **Container pools** group with a card per pool: its labels (with
  `kinhin-container-<name>`), CPUs and memory, `max:`, `min_idle`, Docker, image, whether that image is built (with
  the `kinhin image prepare --container --pool NAME` command when it is not) and which pool takes unmatched jobs.
  **Add Container Pool…**, **Edit…** and **Remove** write `container.pools:`; in the sheet, a blank field leaves the
  key out so the pool inherits the `container:` value its placeholder shows, and **Run flags** takes one argument per
  line. The edit is validated like any config edit and rewrites only the `container:` section (comments inside it are
  not kept); the engine restarts to apply it and keeps the runners it has. The Fleet tab's instance rows and
  **Advanced → Containers** show the pool each container runner belongs to.

Pool names are lowercase letters, digits and inner `-`, up to 32 characters (they end up in a label). The loader also
rejects two pools with the same labels and platform, a `max:` below the pool's `min_idle`, a `platform` other than
`linux/arm64` or `linux/amd64`, and each pool's `flags` by the rules above. Without `pools:`, the `container:` section is one pool and
behaves exactly as before.

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

Install a provider with `kinhin setup repair docker` (Docker Desktop by default; `--method orbstack` or `--method colima`
for the others), see [Installing a Linux runtime](install.md#installing-a-linux-runtime). kinhin never starts or configures
your Docker provider; it only runs containers in it. Run `kinhin image prepare --docker` to bake the agents. Docker slots register with `kinhin-docker`, so jobs opt in with
`runs-on: [kinhin-docker]`. They also inherit the fleet `labels:` minus `macos` (Linux guests); `fleet_labels: false`
trims the pool to `kinhin-docker` (plus the architecture label) alone. `min_idle: N` under `docker:` keeps `N` slots
registered and idle (at most `max_slots`; see [Idle runners per pool and image](scaling.md#idle-runners-per-pool-and-image)).

Prefer a CI-built image? Write a Dockerfile that installs the GitHub Actions runner at `/opt/actions-runner` (with an
executable `config.sh`) and the Gitea runner at `/opt/gitea-runner/gitea-runner`, push it, and set `docker.image:`. Bake
any toolchains into it yourself; kinhin bakes none for Docker.

**amd64 runs under emulation** (Rosetta if enabled in Docker Desktop, otherwise QEMU). Expect slower jobs, and some
software (JITs, certain Go/Java/.NET builds) fails under emulation. Prefer arm64 unless a job needs x86_64. amd64 slots
register with an `x64` label instead of `arm64`, and you must rebuild the image after changing `platform`.

### Start at login

kinhin does not start either container runtime, so after a reboot Linux jobs queue until it is running again. Set
it to start at login. On a headless Mac, also turn on automatic login (see
[Keep it running unattended](rented-mac.md#keep-it-running-unattended)), because both need a login session.

**apple/container.** `container system start` launches the API server as a launch agent, but it registers that
agent from a plist in the container app data directory, not from `~/Library/LaunchAgents`, so nothing starts it at
the next login. Add your own LaunchAgent. Use the path from `which container` (Homebrew on Apple silicon puts it at
`/opt/homebrew/bin/container`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.container-system-start</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/container</string>
        <string>system</string>
        <string>start</string>
        <string>--disable-kernel-install</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

Save it as `~/Library/LaunchAgents/local.container-system-start.plist`. The `--disable-kernel-install` flag stops the
command from prompting at login, so install the kernel first by running `container system start --enable-kernel-install`
once by hand. To test, log out and back in, then run `container system status`. To remove it, run
`launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.container-system-start.plist` and delete the file.

**Docker.** Use the start-at-login setting of your provider:

- **Docker Desktop:** Settings → General → turn on **Start Docker Desktop when you sign in to your computer**
  (off by default).
- **colima:** `brew services start colima` runs colima as a service that starts at login (see the
  [colima FAQ](https://github.com/abiosoft/colima/blob/main/docs/FAQ.md)).
- **OrbStack:** see the [OrbStack documentation](https://docs.orbstack.dev) for its start-at-login setting.

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
kinhin image prepare --source <name> [--target <runner-image>]
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

Runners of the top-level `image:` itself can carry labels too: set top-level `image_labels:`. That is how a Linux
default base answers a label:

```yaml
image: "tahoe-base"
base_image: "ghcr.io/cirruslabs/ubuntu:latest"
labels: [self-hosted, macos, arm64]
image_labels: [linux]
```

A Linux default — whether from `base_image:` or a named image — strips the fleet's `macos` automatically, so macOS
jobs stay on macOS runners. `image_labels:` follows the same rules as a named entry's `labels:` (at least one label
outside the fleet `labels:`, and no label set shared with a named entry); the top-level `warm_pool:` keeps covering
these runners.

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

Precedence: **workflow route → repo route → `runs-on:` label → default**. Capacity is split by the `budget` weights —
each runtime gets its share of the host's CPU cores and of its RAM, and may only run what both allow — and
`kinhin status` shows the result. If a split would leave a configured route with zero capacity, the app warns you
before you can save it.

Manage routes in **Advanced → Routing** (pools with a live health chip, the named
[container pools](#several-container-pools), routes, the default pool, and labels) or with
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
  `kinhin-docker`, `kinhin-host`, and `kinhin-container-<name>` with `--pool NAME` for a
  [named container pool](#several-container-pools)), replacing GitHub-hosted labels the fleet's runners can never
  satisfy with the target pool's exact labels, and stripping stale markers when targeting tart (tart is markerless);
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
- Host routes work for GitHub, Gitea, Forgejo and GitLab (the last three run live in the e2e suite).
