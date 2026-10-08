# The kinhin app

The main window, launch modes, Siri & Shortcuts, and how the app coexists with the headless daemon.

[← Back to README](../README.md)

Install kinhin (see [Install](../README.md#install)), then launch **kinhin** from Applications. The
setup window walks through the same steps as the CLI — installing tart, creating the config,
storing the token, and preparing the image — then starts the fleet. The fleet lives in kinhin's
single main window (and the ○ in your menu bar shows the number of live runner VMs).

## One window, three tabs

Everything kinhin does happens in a single main window. A segmented control switches between:

| Tab          | Contents                                                                                                                                                                                                                                                                                |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Fleet**    | The **Runtimes** diagram: a lane per execution runtime — 🍎 Tart VMs, 🐧 Apple containers, 🐳 Docker, 🖥 Host — holding one icon-led row per live instance — the phase-colored icon, that instance's VM-row detail, and its **Pipeline…**/**Delete** actions (a busy row opens its pipeline) — or the word *idle* when the runtime has nothing running; then live status, Start/Stop/Pause, Current jobs, Queued work, and buttons for Logs and Diagnostics. If the background daemon stops answering, the status line says "Fleet not responding" (with the reason) rather than sending you back to Setup.                                                         |
| **Setup**    | Connect your forges (a grid of GitHub, GitLab, Gitea, Forgejo, Buildkite, Azure DevOps and Bitbucket — select every one to serve), pick the repo or org, get this Mac ready. Toolchains are per repo (see Advanced → Toolchains). First run is a short wizard.                                                  |
| **Advanced** | **Accounts** (forges), **Capacity** (this Mac's macOS and Linux runtimes, the reserve, the budget split between runtimes, VM counts and sizes, with Apply), **Routing** (pools, routes, the default pool, labels), **Containers** (containers and volumes), **Toolchains** (read-only: **Repos** with each project's source and derived images, **Available toolchains**, **Examples**), **App** (launch options, updates, config file).                           |

### This Mac: macOS and Linux jobs

The **This Mac** card (Setup step 2, and Advanced → Capacity) has two parts. **macOS jobs** runs workflows in tart
virtual machines. **Linux jobs** lists, in order, **Tart (Linux VM)**, **Apple container** and **Docker**
(see [Runtimes](runtimes.md#choosing-a-linux-runtime) for the side-by-side comparison and when to use each):

- **Tart (Linux VM)** serves Linux jobs from full tart VMs (VM-grade isolation, no extra runtime to install). Its
  checkbox stays off until tart is installed (use the
  **Install…** button beside it). Turning it on sets the tart base image to a Linux image (Ubuntu by default; Debian
  and Fedora are in the picker) and the macOS base-image picker is replaced by a note. Turning it off returns tart to
  the macOS default. A tart fleet can serve macOS and Linux VMs at the same time when you use named images with
  distinct labels — each VM clones from its own image and advertises only that image's labels. A Linux-named image's
  runners strip the fleet's `macos` label automatically, so they do not attract macOS jobs; you do not need to remove
  `macos` from your fleet `labels:`. See [Tart Linux VMs](runtimes.md#tart-linux-vms).
- **Apple container** and **Docker** each have their own base-image picker (Docker also picks an architecture).

Additional accounts (another org, a second server) are not part of first-run setup; add them under
**Advanced → Accounts → More accounts…**, which opens by itself when extra accounts already exist.

## Live pipeline view

Click a busy VM in the Fleet tab (or its **Pipeline…** button) to see the pipeline it is running. A sheet lists the
pipeline's jobs with their state and elapsed time, the job on this VM marked *this VM*. Click a job to see just its
steps; **‹ All jobs** goes back. The view refreshes every two seconds while it is open, shows the last state when the
job finishes, and **Open in browser** jumps to the run on the forge.

Elapsed times tick every second between refreshes, and each job and step shows when it started or finished ("started 2m
ago", "finished 5s ago"). Click a step (or **Whole job output**) to read its output live: the pane follows the tail as
new lines arrive and shows a **live** mark while the step runs. **‹ Steps** goes back.

What a forge exposes decides how deep it goes (the sheet says so when a forge reports jobs only):

| Forge          | Jobs                      | Steps within a job                         | Output                              |
| -------------- | ------------------------- | ------------------------------------------ | ----------------------------------- |
| GitHub         | every job of the run      | yes                                        | per step (sliced from the job log)  |
| Azure DevOps   | the build timeline's jobs | yes (the job's tasks)                      | per step, and per job               |
| GitLab         | the pipeline's jobs       | no (GitLab's API has no steps below a job) | per job (the trace)                 |
| Buildkite      | the build's script jobs   | no                                         | per job (needs `read_build_logs`)   |
| Bitbucket      | the pipeline's steps      | no (every running step is marked as yours) | per step (Bitbucket's unit)         |
| Gitea, Forgejo | the running task          | no                                         | not available (no stable public API) |

Output is cleaned of terminal colors and keeps the most recent 200,000 characters. A forge may not serve a log until the
step has produced some, so a new step can read "no output yet" for a moment.

The CLI shows the same thing:

```bash
kinhin pipeline                          # every busy VM: its jobs, and the steps of this VM's job
kinhin pipeline kinhin-1700000000-ab12   # one VM
kinhin pipeline kinhin-1700000000-ab12 --job build   # just that job's steps (id, name, or a unique part of it)
kinhin pipeline --watch                  # refresh every 2s (elapsed times and "ago" stay live)
kinhin pipeline --step 2                 # print step 2's output (number, name, or a unique part of it)
kinhin pipeline kinhin-1700000000-ab12 --job build --step Test --follow   # stream it until the step finishes
kinhin pipeline --log --follow           # the whole job's output (with one busy VM, no VM name is needed)
kinhin pipeline --json                   # machine-readable: [{"vm": …, "pipeline": …}]
```

It reads from the running daemon, so it needs `kinhin daemon install` (or `kinhin daemon`) and fails without one.

The data comes from the forge APIs your token already uses, so no extra permission is needed beyond reading jobs
(Azure DevOps also reads the build timeline). Lookups are cached for two seconds per VM to spare the API budget.

## Live CPU and RAM usage

kinhin shows how busy the Mac and each running instance are, so you can tell whether the configured sizes fit
(see [Hardware](hardware.md#watching-real-usage)). It is a current reading, not a history.

- **Menu bar.** The status lines gain a host line, `🖥 Host CPU 34% · RAM 21.0/64 GB`, and each VM row ends with
  ` · CPU 120% · RAM 3.2/8 GB`.
- **Fleet tab.** The same host line and per-VM suffix appear in the VM list.
- **Advanced → Containers.** Rows for running containers show their usage.
- **CLI.** `kinhin status` and `kinhin watch` print a `host:` line and per-VM usage. `kinhin status --json` carries it
  as `fleet.host` and `fleet.records[].usage`.

Host CPU is a percentage of the whole machine; per-VM and per-container CPU is a percentage of **one core**, so it can
exceed 100%. Only active instances are measured. A number that cannot be read is left out (and a warning is logged)
rather than failing the status. CPU needs two samples, so it appears on the second refresh. Usage is never written to
disk. An older daemon simply reports none, and the app shows no usage. How each runtime is measured is in
[Runtimes](runtimes.md#how-usage-is-measured).

Not included: history or graphs, alerts, metrics from inside the guest, and per-job attribution.

## Quitting

With the in-process engine, quitting kinhin waits (up to 30 seconds) for the engine to stop and tear its VMs down
before the app exits. When a background daemon runs the fleet, quitting the app leaves it running.

## Launch mode and login item

Under **Advanced → App**, _Show at launch_ controls how kinhin presents itself (stored in UserDefaults, effective
immediately):

| Show at launch                       | Behavior                                                                               |
| ------------------------------------ | -------------------------------------------------------------------------------------- |
| **Main window + menu bar** (default) | The tabbed window opens at launch and the ○ stays in the menu bar.                     |
| **Main window only**                 | A plain app — no menu bar item; closing the window quits kinhin.                       |
| **Menu bar only**                    | The classic tray app; reopen the window any time from the menu's **Open kinhin** item. |

The same section offers **Launch kinhin at login** (a standard macOS login item via `SMAppService`,
under System Settings → General → Login Items). While the main window is open kinhin runs as a
regular app with a Dock icon; in menu-bar-only mode it stays an accessory app exactly as before.

> **Notarized releases.** Official releases are Developer ID signed and notarized — no
> right-click → **Open** needed. Locally built copies are ad-hoc signed: clear Gatekeeper with
> `xattr -cr /Applications/kinhin.app`.

## Reset kinhin

**Advanced → App → Reset** wipes kinhin's local state — irreversibly. Nothing goes to the Trash and
nothing is backed up; the only way back is setting up again (config, `kinhin auth set`, and
re-baking any image you still want).

The first dialog picks the scope:

| Scope                    | Removes                                                                                                                                          | Keeps                                                                       |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------- |
| **Config & credentials** | `config.yaml` (+ backup), every Keychain token (all accounts, including pre-rename items), logs, local state, the app's preferences and login item | The daemon install, VMs, baked images, the toolchain cache                   |
| **Daemon**               | The LaunchAgent (the running fleet is stopped first)                                                                                              | Everything else — `kinhin daemon install` reinstalls it                      |
| **Everything**           | Both of the above **plus** all runner and scratch VMs, every baked image, the toolchain cache, and the whole `Application Support/Kinhin` folder   | Nothing — a factory reset                                                    |

Then it confirms twice: once with the exact plan (the same list the CLI prints — files, VM names,
image names, cache size, token count), and once by typing `reset`. The button stays disabled until
the word matches. On a config-scoped reset the setup wizard greets the next launch; forge-side
runner registrations are not removed (they show as offline runners in the forge's runner list until
you delete them there).

The CLI does the same thing: `kinhin reset` (interactive, scope menu, two confirmations) or
`kinhin reset --scope config|daemon|all --yes` for scripts.

## Siri, Shortcuts & Spotlight

The menu bar app exposes App Intents (in the release `.app`; `scripts/build-app.sh` generates the metadata), so
you can ask about the fleet without opening a window:

| Say / run                                 | What it does                                                     |
| ----------------------------------------- | -------------------------------------------------------          |
| "How's my kinhin fleet" / "kinhin status" | Running or paused, active VMs, queued jobs, last error           |
| "Start kinhin"                            | Starts a stopped fleet so queued jobs can begin                  |
| "Stop kinhin"                             | Stops the fleet; active VMs are deleted right away               |
| "Pause kinhin"                            | Stops new runner VMs from starting; running jobs finish          |
| "Resume kinhin"                           | Lets a paused fleet start VMs again                              |
| "Delete kinhin VM"                        | Removes one runner VM — pauses the fleet first unless turned off |
| "Diagnose kinhin VM"                      | Phase, assigned job, and last error for one runner VM            |
| "Enable kinhin auto-resume"               | A paused fleet releases itself once the queue is empty           |
| "Disable kinhin auto-resume"              | A pause holds until the fleet is resumed by hand                 |
| "Run kinhin diagnostics"                  | One-line result of the `kinhin doctor` checks                    |

They also appear as actions in Shortcuts, so you can automate them (for example, pause the fleet when a call
starts). Start, stop, pause and resume are idempotent and work with both the in-process engine and the background daemon.

## Playbook: clear a stalled VM from Shortcuts

A VM stuck in `cloning`, `booting` or `registering` (or `failed`) holds its slot. Clear it without opening the window:

1. **Diagnose VM.** Pick the VM from the list. The answer names its phase, assigned job and last error.
2. **Delete VM.** *Pause Fleet First* is on by default, so autoscaling doesn't instantly recreate the VM you deleted.
3. **Enable Auto-Resume.** With [auto-resume](scaling.md#pausing-and-auto-resume) on, the fleet unpauses itself once the queue is empty and scales back up.

Chain the three into one shortcut (say, "clear stalled runner"). Leave *Confirm Before Running* on for the delete step if
it should ask first.

## Headless + menu bar together

The menu bar app runs the engine in-process when no daemon is active, and attaches read/write to
the daemon's unix socket when `kinhin daemon install` has been used. Either way there is exactly
one fleet.

## Troubleshooting: app keeps restarting

If the debug app (`kinhin-app`) keeps launching and exiting in a loop, a launchd job is
probably restarting it. This happens when `scripts/dev-run.sh` is run under launchd
(for example via `launchctl submit`, an Xcode scheme, or a misconfigured plugin) instead
of from a terminal. launchd sees the app exit and restarts the script immediately,
creating an infinite loop.

**To fix:**

1. Kill the stuck job: `launchctl remove kinhin-dev-app`
2. Kill any running instances: `pkill -f "kinhin-app" && pkill -f "dev-run.sh"`

**To prevent it:** always run the debug app from a terminal:

```bash
swift package --disable-sandbox dev
# or directly:
bash scripts/dev-run.sh
```

The `dev-run.sh` script now refuses to run when it detects it is not in a terminal
(no TTY on stdin/stdout), so it will exit with an error instead of entering a restart
loop if launched by launchd.

If you need the app to keep running headless, use the daemon instead:

```bash
kinhin daemon install
```
