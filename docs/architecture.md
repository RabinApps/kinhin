# Architecture

How the Swift package is laid out, what the tests cover, and what CI runs.

[← Back to README](../README.md)

Contributor conventions (layout, style, error handling, formatting) are in [CLAUDE.md](../CLAUDE.md).

## Targets

Single Swift package:

| Target       | Role                                                                                 |
| ------------ | ------------------------------------------------------------------------------------ |
| `KinhinKit`  | Engine: forge clients, runtime abstraction, image pipeline, autoscaler, RPC, daemon  |
| `kinhin`     | CLI                                                                                   |
| `kinhin-app` | Menu bar app (AppKit shell, SwiftUI forms)                                            |

## Source layout

Inside the targets, code is organized by domain:

| Location                    | Contents                                                                                                                                     |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `KinhinKit/Core/`           | Shell, logging, paths, Keychain token store, error classification, version                                                                    |
| `KinhinKit/Config/`         | YAML config model + loader, validation, every config editor, capacity math, config store                                                      |
| `KinhinKit/Forges/`         | One `Forge` protocol; GitHub, Gitea (serves Forgejo too), and GitLab clients over a shared `ForgeHTTP` transport; auth status reporting       |
| `KinhinKit/Runtimes/`       | Runtime protocol, Tart, Apple-container, Docker and Host runtimes, routing pools, capacity partition, daemon-side container manager           |
| `KinhinKit/Fleet/`          | FleetEngine (engine / reload / credentials / reconcile / lifecycle splits), status model, records, daemon dispatch + RPC client/server        |
| `KinhinKit/Images/`         | VM and container image preparation, runner bootstrap scripts, toolchain catalog, registry digest pinning                                       |
| `KinhinKit/Setup/`          | Setup checklist computer, doctor report builder, CLT/tart health probes, host agent installer                                                  |
| `KinhinKit/Cache/`          | Managed-toolchain cache pruning (auto-expiry)                                                                                                 |
| `KinhinKit/Update/`         | GitHub-release update check + DMG download                                                                                                    |
| `kinhin/KinhinCLI.swift`    | @main entry: arg parsing + dispatch only                                                                                                       |
| `kinhin/Commands/`          | One file per command group (auth, doctor, image, run, runtimes, setup) + the CLICommand routing table; shared exit/output/flags helpers        |
| `kinhin-app/AppMain.swift`  | @main entry: AppKit bootstrap, synchronous run loop                                                                                            |
| `kinhin-app/AppDelegate/`   | Lifecycle + backend wiring (in-process engine or daemon RPC) + refresh; extensions for menus, status item, fleet actions, engine reconfig       |
| `kinhin-app/Intents/`       | App Intents (Shortcuts): fleet start/stop/pause, status, delete VM, diagnose, auto-resume; the testable `FleetIntentBridge`                     |
| `kinhin-app/UI/`            | `MainTabsWindowController` (per-tab extension files), `AlertKit`, and shared AppKit plumbing                                                    |
| `kinhin-app/UI/SwiftUI/`    | SwiftUI forms: models (`@Observable`) + views for Connect, This Mac, Routing, Capacity, Toolchains, Containers, the wizard, Diagnostics, Logs   |

Design documents live alongside this file, e.g. [runtime-abstraction-design.md](runtime-abstraction-design.md) (shipped — kept for history).

## Tests

`swift test` runs ~1200 tests across three targets, all against fakes — no VMs or network required:

- **`KinhinKitTests`** (engine, mirrored on the source folders):
  - `Core`: shell, SSH executor, Keychain failure reporting, log redaction, error categories
  - `Config`: config parsing + editors (general/labels/runtimes/budget/toolchains/accounts), capacity, reload policy
  - `Forges`: GitHub/Gitea/GitLab clients over `ForgeHTTP`, demand attribution, registration-token cache, retry/backoff
  - `Runtimes`: Tart + Apple-container + Docker semantics, routing pools, health probes, cache mounts
  - `Images`: image pipeline (tart + container), runner bootstrap scripts, toolchain selection and helper scripts, digest pinning
  - `Fleet`: engine lifecycle, autoscaler, queue attribution (queued and running, per repo), token replacement
    (Keychain upsert, live engine swap, daemon RPC), multi-account engines, recovery
  - `Setup` / `Update` / `Cache`: setup-checklist parity, doctor report, update check, cache pruner
- **`KinhinCLITests`**: command routing table, starter-config auto-create policy, flag parsing,
  status rendering, the `config init` matrix, help text, auth command flows, exit-code classification.
- **`KinhinAppTests`**: menu construction and presentation, status title/line and VM-section
  rendering, the tabbed main window (activation-policy and quit-on-close decisions, Fleet-tab
  status/VM rendering, launch-mode and login persistence, tab switching, delegate plumbing),
  update menu states, update preferences, SwiftUI form models, App Intents through the bridge.

## CI

`.github/workflows/ci.yml` lints, builds (debug and release), and tests on a self-hosted macOS
runner, plus a docs lint on Linux; a scheduled/manual workflow runs the ThreadSanitizer suite.
`release.yml` runs the tests, publishes the DMG, CLI zip, installer, and checksums to GitHub
Releases on `v*` tags, and verifies the stamped version inside the DMG.
