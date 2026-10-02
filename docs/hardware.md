# Hardware requirements & sizing

What your Mac needs to run kinhin, and how to size CPU, memory, and storage for the fleet you want.

[← Back to README](../README.md)

kinhin runs a whole VM (or container) per job, so "how big a Mac do I need" is really "how many
concurrent jobs do I want". The scaler never spawns more than the host can hold — the shapes you
configure decide how much work fits, and `kinhin doctor` tells you what that is. This page is how
to get there deliberately.

## Minimum requirements

| Component  | Minimum                       | Notes                                                                     |
| ---------- | ----------------------------- | ------------------------------------------------------------------------- |
| Chip       | Apple Silicon (any M-series)  | arm64 only; Intel Macs are not supported                                  |
| macOS      | 15 or newer                   | Same as the [install requirements](install.md)                            |
| Memory     | 16 GB                         | 8 GB Macs: Linux containers or a single small [Tart Linux VM](runtimes.md#tart-linux-vms) |
| Free disk  | ~60 GB                        | The prepared base image plus one VM's scratch                             |
| CPU        | Any Apple Silicon (≥ 8 cores) | The default 4-vCPU VM fits beside the `reserve.cpu: 2` headroom           |
| Hypervisor | [Tart](https://tart.run)      | macOS jobs always need it; Linux jobs use apple/container, Docker, or a Tart Linux VM |

The disk minimum covers one VM: the prepared base image takes roughly 40–60 GB (Xcode-baked
images are larger), and each runner VM is a linked clone of it that grows as the job writes.

## What actually limits concurrency

The scaler computes a cap from the host (see [How scaling works](scaling.md#capacity)):

```
cap = min(max_runners,
          (cores − reserve.cpu) / vm.cpu,
          (RAM − reserve.memory_gb) / vm.memory_gb,
          free_disk / disk_per_vm)
```

Three consequences worth knowing before you size anything:

- **The formula is the contract.** The engine never overcommits CPU, RAM, or disk — a burst past
  the cap queues instead of thrashing your Mac.
- **macOS guests cap at two.** Apple's Virtualization framework and license allow two concurrent
  macOS VMs, whatever the hardware (see [Why kinhin](why.md#why-the-usual-workarounds-fall-short);
  Linux guests and containers are not subject to it). Beyond two concurrent macOS jobs the knob is
  `runners_per_vm` — several runner processes share one VM, so size `vm.cpu`/`vm.memory_gb` for
  the _sum_ of those jobs.
- **`kinhin doctor` is the source of truth.** It prints your cores, RAM, free disk, the computed
  cap, and which constraint binds.

## CPU (`vm.cpu`)

A vCPU is a share of the host's logical cores (performance and efficiency alike; the scheduler
decides where work lands). What matters is the sum across VMs staying within `cores − reserve.cpu`:

| Workload                                      | `vm.cpu`            |
| --------------------------------------------- | ------------------- |
| Lint, unit tests, small Node/Go/Python builds | 2                   |
| General-purpose (kinhin's default)            | 4                   |
| Xcode, Rust, C++ — compile-heavy              | 4–6                 |
| Shared VM with `runners_per_vm: 2–3`          | 4–8 (cover the sum) |

- Keep `reserve.cpu` at the default 2 if you work on the Mac while CI runs; 4 on an 8-core base
  chip keeps interactive work snappy, and near 0 only makes sense on a dedicated builder.
- Base chips (8–10 logical cores) fit one 4-vCPU VM comfortably, two only with smaller shapes;
  Pro/Max/Ultra chips (10–16 cores) are where two 4–6-vCPU VMs plus a Linux pool coexist.

## Memory (`vm.memory_gb`)

Memory is the constraint that binds first on most Macs, and the one that makes the machine
unusable if you guess low:

| Workload                                     | `vm.memory_gb`       |
| -------------------------------------------- | -------------------- |
| Lint, unit tests, small services             | 4                    |
| General-purpose (kinhin's default)           | 8                    |
| Xcode small–medium app                       | 8–12                 |
| Xcode large app + simulator runs             | 12–16                |
| Flutter/Android on macOS (Java + Android SDK)| 8–12                 |
| Shared VM with `runners_per_vm: n`           | the sum of the jobs  |

- Validation floors: `vm.memory_gb` ≥ 2, `container.memory_gb` ≥ 2, `docker.memory_gb` ≥ 1.
- Keep `reserve.memory_gb` at the default 4 or more if the Mac is also your daily driver: the
  scaler reserves that RAM on paper, but macOS still swaps when everything wants memory at once.
- 8 GB Macs have no headroom for a useful macOS VM (8 − 4 reserve = 4 GB): use Linux — containers
  or a single small [Tart Linux VM](runtimes.md#tart-linux-vms) — or, for repositories you fully
  trust, [host mode](runtimes.md#host-mode-run-jobs-directly-on-your-mac).

## Storage

What kinhin puts on disk, and how much to plan for:

| Item                                        | Planning number                                                                   |
| ------------------------------------------- | --------------------------------------------------------------------------------- |
| Prepared macOS base image                   | ~40–60 GB (Xcode-baked images: more)                                              |
| Per-instance footprint (`disk_per_vm`)      | 50 GB default for Tart VMs (macOS or Linux) and 8 GB for container slots; override with `disk_gb` |
| Download cache (`toolchain_cache.max_gb`)  | 50 GB default, LRU-pruned with 30-day expiry                                      |
| Host reserve (`reserve.disk_gb`)            | 10 GB default; spawns hold below reserve + one instance's footprint               |

Recommendations:

- **60 GB free** runs the minimum fleet — the base image and one small VM. Fine for trying kinhin.
- **120–250 GB free** for a standing two-VM macOS fleet with Xcode work: two 50 GB footprints,
  the base image, and room for the cache to breathe.
- **300 GB+** if you keep several prepared images (macOS + Linux, Xcode variants) and a fat cache
  (Flutter, Android, Playwright browsers). Reclaim anything stale with
  `kinhin cleanup [--image] [--cache]`.
- Keep `reserve.disk_gb` at 10 or more, and ~10 % of the SSD free overall — APFS degrades when the
  disk is nearly full. The scaler already holds spawns before the reserve is eaten; cache growth
  is bounded separately by [auto-pruning](toolchains.md#expiry-and-pruning).

## Recommended setups

What actually fits, by Mac memory (with the default `reserve.cpu: 2`, `reserve.memory_gb: 4`):

| Mac                    | macOS fleet                                                       | Linux-only alternative         |
| ---------------------- | ----------------------------------------------------------------- | ------------------------------ |
| 8 GB                   | Not recommended — at most one 4 GB VM, nothing else running       | 2 slots × (2 cpu / 2 GB)       |
| 16 GB                  | 1–2 × (3–4 cpu / 6 GB) — two VMs only on 10-core chips            | 3 slots × (2 cpu / 4 GB)       |
| 24 GB                  | 2 × (4 cpu / 8 GB)                                                | 4–5 slots × (2 cpu / 4 GB)     |
| 32 GB                  | 2 × (4–6 cpu / 10–12 GB)                                          | 5–7 slots × (2 cpu / 4 GB)     |
| 48–64 GB               | 2 × (6–7 cpu / 14–16 GB), `runners_per_vm: 2` → 4 concurrent jobs | 6–8 slots × (2 cpu / 4 GB)     |

The macOS shapes assume a 10-core chip or better (2 VMs × 4 vCPU + `reserve.cpu: 2` needs 10
logical cores); on an 8-core base chip, drop to one VM or smaller shapes. Linux slot counts assume
`container.cpus: 2`, `container.memory_gb: 4` — on base chips CPU caps the slots before RAM does
(the 8 GB row shrinks the slots to 2 GB each, which is tight: a runner agent plus any real build
wants more). Two macOS VMs is the ceiling on every row; more concurrent macOS jobs come from
`runners_per_vm`, and Linux pools are bounded by the same CPU/RAM math.

Two worked examples:

A 16 GB Mac mini (M4, 10 cores) serving Linux services CI in apple/container microVMs:

```yaml
max_runners: 3
runtimes:
  default: appleContainer
container:
  image: "kinhin-ci-linux"
  cpus: 2
  memory_gb: 4
```

Cap: (10 − 2) / 2 = 4 by CPU, (16 − 4) / 4 = 3 by RAM — three concurrent jobs.

A 64 GB Mac Studio (M4 Max, 16 cores) for an Xcode fleet with a Linux side pool:

```yaml
max_runners: 2
runners_per_vm: 2
vm:
  cpu: 6
  memory_gb: 14
reserve:
  cpu: 4
  memory_gb: 8
runtimes:
  default: tart
  budget: { tart: 0.7, appleContainer: 0.3 }
container:
  image: "kinhin-ci-linux"
  cpus: 2
  memory_gb: 4
```

Cap: (16 − 4) / 6 = 2 VMs — the macOS ceiling anyway — × 2 runners = 4 concurrent Xcode jobs,
with the container pool taking the remaining budget slice. Budget ~110 GB of disk (2 × 50 GB
footprints + reserve), so the [storage](#storage) recommendation applies.

## Sizing in practice

1. Pick a workload row from the CPU and memory tables above; set `vm.cpu` / `vm.memory_gb`.
2. Set `max_runners` to the concurrency you want — the real cap is the smaller of that and what
   the host can hold.
3. Run `kinhin doctor` and read the binding constraint; adjust the shape or the `reserve:` until
   the cap matches your intent.
4. Watch one real burst with `kinhin watch`: jobs queuing mean too few VMs (or a too-tight cap);
   jobs timing out mean the VMs are too small.

Serving one repo from several Macs splits the load, and each Mac still sizes itself independently
([Running on multiple Macs](scaling.md#running-on-multiple-macs)).

No spare Mac? See [Running kinhin on a rented Mac](rented-mac.md).
