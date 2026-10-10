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
| `toolchains` | One row per catalog tool and stack, per platform: cold install, verify, and a small offline workload. Opt-in: a thorough pass over the whole catalog takes tens of minutes (see [How long it takes](#how-long-it-takes)). |

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

## Example results

Measured on a MacBook with an **Apple M1 Max, 10 cores and 64 GB of RAM**, macOS 27 with Xcode 27.0. Tart VMs had
4 vCPUs and 8 GB (with `tart_softnet: true`), Apple container 1 vCPU and 4 GB, Docker 2 vCPUs and 4 GB, all
`linux/arm64`. Unless noted these are `--quick` runs, so each number is a single sample. Your Mac, image and load will
differ: use them to see the shape of the report, not as a promise.

**Boot** (`kinhin bench boot`, thorough, 2 iterations for Tart):

| Runtime         | Phase                        | Median  |
| --------------- | ---------------------------- | ------- |
| Tart (macOS VM) | `clone`                      | 74 ms   |
|                 | `boot-to-IP`                 | 1.1 s   |
|                 | `IP-to-SSH-ready`            | 30.9 s  |
|                 | `cold-boot-total`            | 32.0 s  |
|                 | `warm-stop` / `warm-boot`    | 0.5 s / 10.6 s |
| Apple container | `start` / `exec-ready`       | 2.1 s / 112 ms |
| Docker          | `start` / `exec-ready`       | 268 ms / 102 ms |

The Tart `IP-to-SSH-ready` figure includes the 30 s window kinhin spends trying to pin the guest's SSH host key
through the guest agent; the near-identical 31 s in both iterations suggests this test image's guest agent did not answer, so the
full window elapsed before the connection was made (see [Security](security.md)).

**Casual, Xcode and Large** (Tart macOS VM versus a Docker container; `swift build` and Xcode need the macOS guest):

| Step                 | Tart (macOS) | Docker (Linux) |
| -------------------- | ------------ | -------------- |
| `exec-overhead`      | 161 ms       | 64 ms          |
| `file-create`        | 237 MB/s     | 647 MB/s       |
| `tar-gzip`           | 38.9 MB/s    | 42.9 MB/s      |
| `untar`              | 325 MB/s     | 193 MB/s       |
| `checksum`           | 151 MB/s     | 224 MB/s       |
| `git-commit`         | 296 ms       | 109 ms         |
| `swift-build`        | 16.5 s       | skipped (no Swift in the image) |
| Xcode `clean-build`  | 13.1 s       | n/a            |
| Xcode `incremental-build` | 3.2 s   | n/a            |
| `disk-write`         | 750 MB/s     | 569 MB/s       |
| `disk-read` (cached) | 2.9 GB/s     | 2.7 GB/s       |
| `cpu-gzip`           | 163 MB/s     | 53 MB/s        |
| `git-clone` (`--network`, shallow) | not run | 1.0 s |

**Toolchains** (`kinhin bench toolchains --thorough`, one fresh Docker container per tool, cold install with no shared
cache):

| Tool       | Install | Workload                    |
| ---------- | ------- | --------------------------- |
| `typescript` | 4.7 s | `tsc`, 318 ms (node already present) |
| `bun`      | 11.6 s  | script, 132 ms              |
| `just`     | 11.5 s  | `just`, 80 ms               |
| `helm`     | 11.5 s  | `helm create` + `template`, 123 ms |
| `terraform` | 12.3 s | `validate`, 121 ms          |
| `node`     | 13.8 s  | script, 101 ms              |
| `go`       | 14.2 s  | `go build`, 3.6 s           |
| `dotnet`   | 16.5 s  | `dotnet new` + `build`, 6.5 s |
| `python`   | 18.0 s  | script, 252 ms              |
| `java`     | 22.0 s  | `javac` + `java`, 487 ms    |
| `zig`      | 24.5 s  | `zig run`, 8.6 s            |
| `julia`    | 27.0 s  | script, 309 ms              |
| `maven`    | 43.3 s  | `mvn validate`, 966 ms      |

The same run reported tools that did not install in that container image as `failed` rows with the installer's output
(`elixir` needs `erl`, `lua` needs a C toolchain to build, `swift` failed extracting its archive), and `cmake` and `rust`
as verify-only because the image has no C compiler. That is the point of the table: it doubles as an install check.

## How long it takes

Measured on the M1 Max above (fast home connection, nothing else running):

| Run                                                                  | Time          |
| -------------------------------------------------------------------- | ------------- |
| `kinhin bench boot --runtime docker,appleContainer`                  | about 4 s     |
| `kinhin bench casual large --runtime docker` (with `--network`)      | about 15 s    |
| `kinhin bench casual xcode large --runtime tart`                     | about 1.5 min |
| `kinhin bench boot --runtime tart --thorough --iterations 2`         | about 1.5 min |
| `kinhin bench toolchains --thorough --all-toolchains`, macOS (4 category VMs, 66 rows) | about 15 min  |
| the same, Linux on Apple container (one container per tool, 65 rows) | about 25 min  |
| `kinhin bench toolchains` (quick: verify + workload, nothing installed) | minutes     |

The toolchains pass is dominated by downloads, so a slow connection can multiply it. The app and `bench_status` report
elapsed time and the current step while it runs.

## What has been tested

Honest status of this feature, as of the first complete implementation.

**Tested by the automated suite** (`swift test`, no VMs or network): the runner against the shared fakes (boot phases,
every suite's steps, cleanup on success, failure and cancel, fleet pause/resume/drain, the stray sweep, preflight
errors), the report and history store, the RPC handler and registry, the CLI parser and daemon polling, the app model,
the toolchain coverage invariants (every catalog tool and stack, on every platform it claims, has a plan and a
workload or a skip reason), and the stdin-isolating script wrapper against a real `bash`. A ThreadSanitizer run over
these tests found no races.

**Tested for real**, on an Apple M1 Max (64 GB), against real runtimes:

- **Tart macOS VM** (a 73 GB Xcode 27 image): `boot` (cold and warm, 2 iterations), `casual`, `xcode` (generated
  package and `--project` with a real Swift package), `large`, and the full toolchain catalog, installed cold (66 rows, none failed, 15 min).
- **Apple container** (`kinhin-ci-linux`): `boot` and the full toolchain catalog, installed cold. The last complete
  run predates two late fixes (stdin isolation, the gem path); a final full rerun was interrupted, and the affected
  entries (`fastlane`, `gcloud`, `swift`, `lua`, `elixir`) were re-run individually and pass.
- **Docker** (`kinhin-ci-linux`): `boot`, `casual`, `large` including `--network` (a real shallow clone), and about
  45 catalog tools installed cold.
- Cleanup was checked after each run: no `kinhin-bench-*` VM or container remained.
- The daemon methods (`bench_start`, `bench_status`, `bench_cancel`, including a cancelled run) over a real unix
  socket served by `RPCServer` with a throwaway engine.
- The Benchmarks view was rendered to an image from a real report to check its layout.

**Not tested yet:**

- Running through an actual `kinhin daemon` process (it would start the fleet, so the RPC path was exercised with a
  throwaway engine on a real socket instead).
- The app as a running window: clicking **Run…**, the confirmation dialog, live progress while a run goes, and the
  Fleet tab card. The model is unit-tested and the view renders, but nobody has used it end to end.
- Pausing a real fleet that has live, busy VMs (the pause, drain and resume logic is covered only with fakes), and the
  interactive confirmation prompt on a terminal.
- `--include-host` against the real host runtime (only a faked shell).
- The `linux/amd64` emulation pass on Docker, and a Docker run of the _whole_ catalog (about 45 tools were run; the
  Docker VM here was nearly out of disk, so `swift` was reported `skipped`, which is the intended behaviour).
- Tart Linux guests, thorough runs with more than two boot iterations, `--project` with an `.xcodeproj` or
  `.xcworkspace` (only a bare Swift package was built), and Intel Macs or other Xcode versions.

## How results are judged

- Entries that need build tools the base image lacks (a C toolchain for `lua`, `rust` and `cmake`, Python for
  `gcloud`, shared libraries for `swift`, Erlang for `elixir`, a modern Ruby and the gem `bin` directory for
  `fastlane`, the Flutter SDK step for `flutter`) get them as untimed prerequisites, so the run measures the tool and
  not the base image.
- An install that dies because the guest ran out of disk is reported `skipped` with the free space, not `failed`.
- A Tart VM that never gets a network lease gets one retry with a fresh VM.

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
