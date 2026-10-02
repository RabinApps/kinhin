# Beta test log

Results from the beta test pass, newest first. "Live" means run on a real Mac with real VMs or services.

| Date | Area | Result |
| ---- | ---- | ------ |
| 2026-10-01 | GitHub org runner registration URL | Found and fixed: `config.sh --url https://github.com/organizations/<org>` got 404 from runner-registration; org runners now use `https://github.com/<org>` and register (live) |
| 2026-10-01 | Tart + softnet runner VM, end to end (GitHub org scope, live) | Works: daemon saw the queued job, cloned `tahoe-base`, booted under softnet, registered a runner, ran the job, deregistered it and deleted the VM (no leftovers). Needs softnet's one-time root setup (now in docs/runtimes.md) |
| 2026-10-01 | SSH readiness after boot | Found and fixed: `tart ip` answers ~20 s before sshd listens, so registration failed with "Operation timed out". Registration now retries those errors for up to 2 minutes |
| 2026-10-01 | Workflow job on the baked image | Job ran, checkout and lint passed, `swift build` failed: the runner used Swift 6.3.3 instead of the baked 6.4.0 (runner PATH does not put mise shims first). Open |
| 2026-10-01 | GitHub job polling (org scope, live) | Found and fixed: org scope read only the first 20 repos in API order, so a queued job in the 28th repo was invisible (queue depth 0 vs 1 on GitHub). Repos are now read most-recently-pushed first. After the fix the daemon reported `RabinApps/kinhin: 1` queued and scaled up. Per-repo reads, label matching and in_progress/queued counts agree with `gh` |
| 2026-10-01 | Tart image `kinhin image prepare` (macOS, 9 toolchains incl. rust) | Passes live. Found and fixed: `tart list --quiet` now prints names only, so the old image was never detected and the commit failed with "already exists" |
| 2026-10-01 | Runtime default with a `container:` section and no `runtimes:` block | Whole fleet silently uses apple/container, so a macOS job was sent to a Linux container. Work-around: set `runtimes: default: tart`. Needs a doc note or a safer default |
| 2026-10-01 | `image prepare --container` / `--docker` with swift@latest | Failed live: swift 6.4 needs system libraries (libncurses, libedit, libxml2, libsqlite3, libpython) missing from the ubuntu:24.04 image |
| 2026-10-01 | Unit suite (`swift test`, KinhinKit, CLI and app targets) | Passes except two `RegistryDigestResolverTests` cases left half-edited (cirruslabs/openai rename) |
| 2026-10-01 | Tart macOS guest over SSH, all nine configured toolchain specs via `mise use --global` (non-TTY, guest-local cache) | Installed and ran live (go 1.27.1, python 3.13.15, ruby 4.0.7, java 21, bun 1.4.2, uv 0.12.21, swift 6.4.0, cargo 1.99.0). Finding: `node --version` reported 24.20.0, not the pinned 22, because the base image's Homebrew node comes first on PATH ahead of the mise shims. Fixed: the bake PATH now puts the shims first; verified live (node 22.23.3) and covered by unit tests |
| 2026-10-01 | Tart macOS guest over SSH, rust via `mise use --global rust@stable` with the guest-local cache (non-TTY) | Works live (cargo 1.99.0). Not yet confirmed through a full `image prepare` |
| 2026-10-01 | Tart macOS guest networking, default shared (NAT) mode on macOS 27 | Failed live: the guest got a lease but the host could not reach it. Bridged mode worked. Cause is probably the host's vmnet, not kinhin |
| 2026-10-01 | `image prepare` scratch-VM cleanup on failure | Fixed and covered by unit tests; seen working live (scratch VM removed after a failed run) |
| 2026-10-01 | Default Tart base image `ghcr.io/openai/macos-tahoe-base` | Anonymous pull returned 403; the default now points at the cirruslabs image |
| 2026-10-01 | Docker, apple/container | Installed and running on the test Mac; no workflow run yet |
