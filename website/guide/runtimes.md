# Runtimes & routing

Every job is placed on a **Runtime** — a pluggable executor that provisions instances, runs the
agent, and tears down. Three backends ship:

| Runtime                | Runs       | Isolation                                                        |
| ---------------------- | ---------- | ---------------------------------------------------------------- |
| **Tart**               | macOS jobs | full macOS VM per job (linked clone of a prepared base image)     |
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
runners always register with an `orchard-container` label (plus optional `container.labels`),
so any job can opt into the Linux pool with `runs-on: [orchard-container]` without touching
config.

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

## Inspecting the split

`kinhin runtimes` (or the menu bar's **Runtimes…** pane) shows the pools with their per-runtime
caps and budget shares, plus every route (repo and workflow). Each pool card carries a **live
health chip** (● ready / ● missing / ● error) from the runtime's own probe, and the pane's
**Budget** card edits the split directly with a live cap preview per row.
