# Plan: show progress for image downloads and builds

Status: not started. Post-beta improvement.

## Context

`kinhin image prepare` can take a long time (the Tart base image is tens of gigabytes), and kinhin shows nothing while it runs:

- `TartController.pull` (`Sources/KinhinKit/Runtimes/Tart.swift`) runs `tart pull` through `ShellRunning.run(_:cwd:timeout:)`, which collects stdout and stderr and returns them only when the process exits. Tart's own progress bar never reaches the user.
- The only feedback is one `Log.info` line from `ImagePreparer.run` ("ensuring base image … this can download gigabytes once"), and then silence.
- The one-hour `pull` timeout can fire silently on a slow link.
- The Linux image builds (`ContainerImagePreparer`, `DockerImagePreparer`, `LinuxImageBaker`) have the same shape: long `container build` / `docker build` calls with no live output. The only progress code in kinhin is the updater's DMG download (`DownloadProgressDelegate`, `UpdateCheck.swift`).

Goal: a user watching `kinhin image prepare`, the setup wizard, or the Setup tab can see that work is happening, how far along it is when that is knowable, and why it failed.

## Spike first (decides the design)

Before writing code, check what `tart pull` actually emits when stdout and stderr are pipes rather than a TTY:

1. Run `tart pull <small-or-cached-image>` with output redirected to a file, and look at the bytes. Does it print percentages or a bar, use `\r` redraws, or print nothing without a TTY?
2. Check the same for `docker build` (`--progress=plain`) and `container build`.

Outcomes:
- **Percentages appear on a pipe:** parse them (step 2 below).
- **Nothing appears without a TTY:** fall back to measuring bytes on disk (see "Fallback"), or run the child under a pseudo-terminal.

## Design

### 1. Streaming shell runner (`Sources/KinhinKit/Core/Shell.swift`)
- Add a streaming method to `ShellRunning`, e.g. `run(_:cwd:timeout:onOutput:)`, where `onOutput` receives chunks of stdout/stderr as they arrive (`@Sendable`). Give the protocol extension a default that calls the existing `run` and emits the whole output at the end, so `FakeShell` and every existing conformer keep working.
- `Shell` implements it by reading the pipes incrementally instead of at exit. Split on both `\n` and `\r`, since progress bars redraw with carriage returns.
- Keep secrets safe: output passes through `Log.redact` before it reaches any callback or log, as with the existing runner output.
- Honor cancellation and the timeout exactly as today. `CancellationError` must propagate.

### 2. Progress model (`Sources/KinhinKit/Images/ImageProgress.swift`)
- A small `Sendable` value, e.g. `ImageProgress { phase: Phase, fraction: Double?, detail: String? }`, with phases such as `pulling`, `cloning`, `provisioning`, `building`, `exporting`. `fraction` is `nil` when unknown (spinner), a number when known.
- A pure parser `TartPullProgressParser` (and a plain-line parser for docker/container) that turns output chunks into `ImageProgress`. Pure functions, so they are easy to unit test with captured real output as fixtures.

### 3. Plumb it through the preparers
- `TartRuntime.pull(image:progress:)` and `TartController.pull`: add an optional `progress: (@Sendable (ImageProgress) -> Void)? = nil` parameter (default `nil`, so existing callers and `FakeTart` compile unchanged).
- `ImagePreparer.Options` and `ImageBuildService.rebuild` take an optional progress handler and report phase changes (pull, clone, boot, provision, export) so the user sees which step the build is on even when the fraction is unknown.
- `ContainerImagePreparer` and `DockerImagePreparer` forward build output lines as `detail` text and report phases.
- Keep the existing `Log.info` lines. Log at most one line per ~10% step, not every chunk, so the log ring buffer is not flooded.

### 4. Surfaces
- **CLI** (`kinhin image prepare`): on a TTY, a single live line on stderr (`pulling base image  42%  ↓ 12.3 MB/s`). On a non-TTY (CI, pipes), plain lines at 10% steps. stdout stays clean for `--json`. Respect `NO_COLOR`.
- **App wizard and Setup tab** (`Sources/kinhin-app/UI/SwiftUI/...`, e.g. the toolchains and Mac steps in `WizardModel`, `MacToolsModel`): show a determinate `ProgressView(value:)` when `fraction` is known, an indeterminate one with the phase label otherwise, plus a Cancel button wired to the existing task cancellation. Handlers are `@MainActor`-hopped by the model, not by the engine.
- **Doctor / Diagnostics:** while a build is running, show "image: preparing (pulling, 42%)" instead of "image not built yet".

### Fallback (only if the spike shows no usable output)
Poll the size of Tart's cache directory (`~/.tart/cache/OCIs/...`) every second while `pull` runs and compare against the expected size from the registry manifest. This gives bytes and speed but no exact percentage, and it depends on Tart's private cache layout, so mark it best-effort and fall back to an indeterminate bar when the directory is not found. Alternatively run the child under a pty so Tart believes it has a terminal. Pick whichever the spike shows is more reliable.

## Timeouts
Replace the flat one-hour `pull` timeout with an inactivity timeout (fail only if no output or growth for N minutes), so a slow but progressing download is never killed, and a stalled one is reported with a clear `TartError` message.

## Tests
- **Parser:** fixtures of real `tart pull`, `docker build --progress=plain`, and `container build` output (percentage lines, `\r` redraws, truncated or garbled lines, empty output). Assert fractions are monotonic and clamped to 0...1.
- **Shell:** the streaming runner delivers chunks before the process exits (a script that prints, sleeps, then prints), splits on `\r`, redacts secrets, and respects timeout and cancellation.
- **Preparers:** with `FakeTart` and `FakeShell`, assert phases are reported in order, and that calling without a handler behaves exactly as before.
- **Surfaces:** `WizardModelTests`/`MacToolsModel` tests for the progress state transitions and Cancel; a CLI test that non-TTY output is plain lines on stderr and stdout is untouched.
- Run `swift test` and `scripts/tsan.sh` (callbacks cross threads).

## Docs
Mention the live progress in `docs/install.md` and the image-prepare section of the README, and add a `CHANGELOG.md` entry.
