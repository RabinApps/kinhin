# The kinhin app

The main window, launch modes, Siri & Shortcuts, and how the app coexists with the headless daemon.

[← Back to README](../README.md)

Install kinhin (see [Install](../README.md#install)), then launch **kinhin** from Applications. The
setup window walks through the same steps as the CLI — installing tart, creating the config,
storing the token, and preparing the image — then starts the fleet. The fleet lives in kinhin's
single main window (and the ○ in your menu bar shows the number of live runner VMs).

## One window, three tabs

Everything kinhin does happens in a single main window. A segmented control switches between:

| Tab          | Contents                                                                                                                                    |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| **Fleet**    | Live status, Start/Stop/Pause, the VM list, and buttons for Logs, Diagnostics and update checks.                                            |
| **Setup**    | Connect GitHub (and optionally Gitea), pick the repo or org, get this Mac ready, then choose your toolchains. First run is a 4-step wizard. |
| **Advanced** | **Capacity** (VM counts and sizes, with Apply), **Routing** (runtimes, budget, labels), **App** (launch options, config file).              |

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
> `xattr -cr /Applications/kinhin.app`. (Homebrew's cask verifies the sha256, so
> `brew install --cask kinhin` is the smoothest path; see [Install](install.md#homebrew).)

## Siri, Shortcuts & Spotlight

The menu bar app exposes App Intents (in the release `.app`; `scripts/build-app.sh` generates the metadata), so
you can ask about the fleet without opening a window:

| Say / run                                 | What it does                                            |
| ----------------------------------------- | ------------------------------------------------------- |
| "How's my kinhin fleet" / "kinhin status" | Running or paused, active VMs, queued jobs, last error  |
| "Pause kinhin"                            | Stops new runner VMs from starting; running jobs finish |
| "Resume kinhin"                           | Lets a paused fleet start VMs again                     |
| "Run kinhin diagnostics"                  | One-line result of the `kinhin doctor` checks           |

They also appear as actions in Shortcuts, so you can automate them (for example, pause the fleet when a call
starts). Pause and resume are idempotent and work with both the in-process engine and the background daemon.

## Headless + menu bar together

The menu bar app runs the engine in-process when no daemon is active, and attaches read/write to
the daemon's unix socket when `kinhin daemon install` has been used. Either way there is exactly
one fleet.
