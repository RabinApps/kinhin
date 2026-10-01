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
| **Fleet**    | Live status, Start/Stop/Pause, the VM list, and buttons for Logs and Diagnostics. If the background daemon stops answering, the status line says "Fleet not responding" (with the reason) rather than sending you back to Setup.                                                         |
| **Setup**    | Connect your forges (a grid of GitHub, GitLab, Gitea, Forgejo, Buildkite, Azure DevOps and Bitbucket — select every one to serve), pick the repo or org, get this Mac ready, then choose your toolchains. First run is a 4-step wizard.                                                  |
| **Advanced** | **Accounts** (forges and this Mac), **Capacity** (VM counts and sizes, with Apply), **Routing** (runtimes, budget, labels), **Containers** (containers and volumes), **Toolchains** (bake tools into images), **App** (launch options, updates, config file).                           |

### This Mac: macOS and Linux jobs

The **This Mac** card (Setup step 2, and Advanced → Accounts) has two parts. **macOS jobs** runs workflows in tart
virtual machines. **Linux jobs** lists, in order, **Tart (Linux VM)**, **Apple container** and **Docker**:

- **Tart (Linux VM)** serves Linux jobs from full tart VMs. Its checkbox stays off until tart is installed (use the
  **Install…** button beside it). Turning it on sets the tart base image to a Linux image (Ubuntu by default; Debian
  and Fedora are in the picker) and the macOS base-image picker is replaced by a note. Turning it off returns tart to
  the macOS default. A tart fleet serves one OS at a time, and your fleet `labels:` must match: if they still include
  `macos`, the card warns you to remove it (and add `linux` if your jobs ask for it). See
  [Tart Linux VMs](runtimes.md#tart-linux-vms).
- **Apple container** and **Docker** each have their own base-image picker (Docker also picks an architecture).

Additional accounts (another org, a second server) are not part of first-run setup; add them under
**Advanced → Accounts → More accounts…**, which opens by itself when extra accounts already exist.

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

A VM stuck in `cloning`, `booting` or `registering` (or `failed`) holds its slot hostage. You can
clear it without opening the window — every step is a kinhin action in Shortcuts, or ask Siri:

1. **Diagnose.** Run **Diagnose VM** and pick the VM from the picker (every current VM, listed
   with its phase). The answer names the phase, the assigned job, and the last error — enough to
   decide whether it is truly stuck.
2. **Delete with pause-first.** Run **Delete VM** for that VM. *Pause Fleet First* is on by
   default: kinhin pauses the fleet, deletes the VM, and holds autoscaling so the stalled VM is
   not instantly recreated. A job that was waiting for it simply waits for the next VM.
3. **Let it release.** With auto-resume on (Advanced → Capacity, or the **Enable Auto-Resume**
   action — it reports and no-ops when already on), the status line — menu bar, Fleet tab,
   `kinhin status` — shows "auto-resume: re-checks the queue every 20s and resumes once it's
   empty" while the fleet holds (the seconds match your `poll_interval`; without a cadence from
   an older daemon, the short "releases when the queue is empty" appears instead). The engine
   unpauses itself the moment a check finds the queue empty and scales back up.

Chain the steps into one shortcut (Diagnose VM → Delete VM → Enable Auto-Resume) and name it,
say, "clear stalled runner". Leave Shortcuts' *Confirm Before Running* on for the delete step if
it should ask before destroying anything; turn it off to make the whole flow one tap or one
spoken command. With auto-resume off instead, resume by hand — the menu's **Resume** or
"Resume kinhin".

## Headless + menu bar together

The menu bar app runs the engine in-process when no daemon is active, and attaches read/write to
the daemon's unix socket when `kinhin daemon install` has been used. Either way there is exactly
one fleet.
