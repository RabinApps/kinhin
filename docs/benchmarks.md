# Benchmarks

`kinhin bench` measures, on this Mac, how fast every runtime boots, how fast representative workloads run inside
them, and how fast every toolchain in the [catalog](toolchains.md) installs and builds. It writes a
machine-readable report and removes everything it created. The same runs are available in the app under
**Advanced → Benchmarks**.

Use it to answer questions like _which runtime boots fastest here_, _what does Xcode cost on this machine_, _is my
disk the bottleneck_, or _how long will a fresh image take to bake_ — and to compare a change (a new image, a
different VM size, `tart_softnet`) before and after.

```sh
kinhin bench                         # boot, casual, xcode and large; minutes
kinhin bench boot --thorough         # 3 boot iterations per runtime, with min/median/max
kinhin bench xcode --project ~/src/MyApp
kinhin bench toolchains              # verify + a tiny build of every catalog tool (minutes)
kinhin bench toolchains --thorough --toolchains node,go,rust   # time the cold install too
kinhin bench --json > bench.json     # the report, on stdout only
```

## The suites

| Suite        | What it measures                                                                                                                                         |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `boot`       | One row per runtime. Tart: `clone`, `boot-to-IP`, `IP-to-SSH-ready`, the cold total, and a warm stop/start. Containers: `start` and `exec-ready`. Host: `spawn` and `ready`. |
| `casual`     | One shared guest: per-exec overhead, a file tree (create, tar+gzip, untar, checksum), `git` commit of hundreds of files, and a `swift build` of a small generated package. |
| `xcode`      | `xcodebuild` clean and incremental builds of a generated multi-file Swift package, or of your checkout with `--project`. Skipped when the guest has no Xcode. |
| `large`      | Multi-gigabyte disk write, read and checksum, multi-core gzip throughput, and (with `--network`) a timed shallow `git clone`.                              |
| `toolchains` | One row per catalog tool and stack, per platform: cold install, verify, and a small offline workload. Opt-in, because the thorough pass takes hours.      |

`--quick` (the default) uses one boot iteration and small payloads. `--thorough` uses three iterations and larger
payloads (still capped at 4 GB), and makes the toolchains suite time the cold install.

Every suite names the runtime and guest platform it measured, so two runs compare across runtimes. Boot covers every
runtime whose prerequisites are healthy on this Mac, configured or not; a runtime that cannot run appears as
`skipped` with the reason (and `host` appears as skipped until you pass `--include-host`).

### Reading the numbers

- Timing is taken on the host around each command, so each step includes one command round trip. The
  `exec-overhead` step in `casual` is that round trip alone; subtract it when a step is short.
- Docker with `linux/amd64` runs under emulation and is much slower than `linux/arm64`. Thorough boot runs add a
  separate `linux/amd64` row when an amd64 image is on this Mac.
- `disk-read` can be served from the guest's page cache; read it as a ceiling.
- A toolchain row marked `preinstalled` was already in the image, so no install was timed. A quick run never installs:
  a tool the image lacks reads `skipped`.
- Tools with no meaningful offline workload (`playwright`, `cypress`, `fastlane`, `netlify-cli`, `k9s`, `pulumi`,
  `vault`, …) are verify-only and say why.

## Flags

| Flag                              | Meaning                                                                                  |
| --------------------------------- | ---------------------------------------------------------------------------------------- |
| `boot casual xcode large toolchains` | Which suites to run (default: the first four).                                        |
| `--quick` / `--thorough`          | Payload sizes and iterations.                                                            |
| `--iterations N`                  | Boot iterations, 1 to 10.                                                                |
| `--runtime tart,docker,…`         | Only these runtimes (`tart`, `appleContainer`, `docker`, `host`, `all`).                 |
| `--toolchains ID,…`               | Scope the toolchains suite to these tools or stacks.                                     |
| `--all-toolchains`                | Cover the whole catalog (required for a thorough run that is not scoped).                |
| `--include-host`                  | Also benchmark the unisolated host runtime — see below.                                  |
| `--network URL`                   | Time a shallow `git clone` of an `https://`, `ssh://` or `git://` URL inside the guest.  |
| `--project PATH`                  | Copy a checkout into the macOS guest and build it with `xcodebuild`.                     |
| `--yes`                           | Agree to pause a running fleet without asking.                                           |
| `--force`                         | Do not wait for busy fleet VMs to finish before measuring.                               |
| `--keep`                          | Keep the host scratch directory (for debugging).                                         |
| `--json`                          | Print the report as the one JSON document on stdout; progress is silenced.               |

Exit codes follow the usual rule: 0 when every suite ran or was skipped, 1 when a suite or a toolchain
row failed, 2 for a bad command line, 4 when a benchmark could not run at all (a runtime or image is missing, not enough
free disk, the fleet would not drain).

## What it creates, and what it removes

**Created during the run, removed afterwards — also when the run fails or is cancelled:**

- Tart VMs and containers named `kinhin-bench-*`, cloned from your configured image. They are stopped and deleted, and
  their pinned SSH host keys are dropped.
- A `kinhin-bench/` directory inside each guest. (Deleting the guest discards it anyway.)
- A host scratch directory, `~/Library/Application Support/Kinhin/bench/<run-id>/`, holding generated sources and the
  `--project` archive. Removed whole unless `--keep`.

**Kept:** the report, `results-<timestamp>-<id>.json` in `~/Library/Application Support/Kinhin/bench/`, newest 20.
Reports hold no credentials. The base image, the config file, the Keychain and the toolchain cache are never touched.

A crashed run can leave a `kinhin-bench-*` VM behind. The next `kinhin bench` sweeps it up before it starts, and
`kinhin cleanup` lists it with the other leftover VMs.

## The fleet is paused while it runs

A benchmark needs the Mac to itself, so a running fleet is held while it measures:

1. If the fleet has live VMs, the CLI asks first (`--yes` agrees up front; a script that is not attached to a terminal
   must pass it). The app shows a confirmation dialog.
2. New spawns are paused and busy VMs are given up to ten minutes to finish their jobs (`--force` skips the wait).
3. The fleet is resumed when the run ends, including on failure or Ctrl-C. A fleet that was already paused is left
   paused.

With a daemon running, the daemon performs the run and pauses itself (the CLI polls for progress; Ctrl-C cancels the
run there too). With no daemon, the CLI runs the benchmark in its own process.

## Safety

- **No secrets.** A benchmark never reads the Keychain, mints a registration token or registers a runner, so no
  credential reaches a bench VM, a script or a report.
- **Same guest access as runners.** Bench guests are reached the way runner VMs are: kinhin's guest key, a per-VM
  pinned host key, and the image's hardened SSH. Bench VMs boot with your `tart_softnet` setting.
- **Bounded input.** `--project` is copied into the guest (never mounted) with relative-only archive extraction and
  is capped at 128 MB after excluding `.git`, `.build` and `node_modules`. `--network` accepts only git URL schemes
  and clones inside the disposable guest. Generated scripts quote every interpolated value, and nothing is ever
  piped from the network into a shell.
- **Offline toolchain workloads.** Workloads build generated sources only. Cloud CLIs run local flags, never live
  services.
- **Host mode is consent-gated.** `--include-host` mirrors the consent rule for host routes: the host runtime has no
  isolation, so it only runs when you ask, in a scrubbed scratch directory.
- **Limits.** Payload and iteration sizes are capped whatever the flags say, free disk is checked first, every command
  has a timeout, and cancelling tears everything down.

## From the app

**Advanced → Benchmarks** has a toggle per suite, a Quick/Thorough picker and a **Run…** button that confirms the
fleet pause. While a run is going it shows live progress, then the cross-runtime boot comparison, each suite's steps,
a sortable toolchains table (skip reasons inline) and the history of earlier reports. The Fleet tab has a card that
opens it. The app polls the run every two seconds, so closing the window does not stop it; reopening the section
re-attaches.

## Under the hood

`bench_start`, `bench_status` and `bench_cancel` are daemon RPC methods (see [architecture](architecture.md)): a run
outlives an RPC deadline, so the daemon starts it detached and clients poll its status. The measuring is
`BenchmarkRunner` in `Sources/KinhinKit/Benchmarks/`.
