# Architecture

How the Swift package is laid out, what the tests cover, and what CI runs.

[← Back to README](../README.md)

Contributor conventions (layout, style, error handling, formatting) are in [CLAUDE.md](../CLAUDE.md).

## Targets

Single Swift package:

| Target       | Role                                                                       |
| ------------ | -------------------------------------------------------------------------- |
| `KinhinKit`  | Engine: GitHub client, Tart wrapper, SSH executor, autoscaler, RPC, daemon |
| `kinhin`     | CLI                                                                        |
| `kinhin-app` | Menu bar app (AppKit)                                                      |

## Source layout

Inside the targets, code is organized by domain:

| Location                   | Contents                                                                                                                                      |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `KinhinKit/Core/`          | Shell, logging, paths, keychain, RPC, mutex/box primitives                                                                                    |
| `KinhinKit/Config/`        | YAML config, validation, template, capacity math, runtime routing                                                                             |
| `KinhinKit/Forges/`        | GitHub + Gitea forges, org-permission probe                                                                                                   |
| `KinhinKit/Runtimes/`      | Runtime protocol, Tart, Apple-container, Docker and Host runtimes, routing pools                                                              |
| `KinhinKit/Fleet/`         | FleetEngine (split: shell / reconcile / lifecycle), status model, records                                                                     |
| `KinhinKit/Images/`        | VM and container image preparation                                                                                                            |
| `KinhinKit/Setup/`         | Setup checklist, doctor probes (tart health, CLT)                                                                                             |
| `KinhinKit/ViewModels/`    | UI-agnostic view models (setup checklist rows, Routing pane)                                                                                  |
| `KinhinKit/Update/`        | GitHub-release update check                                                                                                                   |
| `kinhin/KinhinCLI.swift`   | @main entry: arg parsing + dispatch only                                                                                                      |
| `kinhin/Commands/`         | One file per command group (auth, doctor, image, run, runtimes, setup) + the CLICommand routing table                                         |
| `kinhin-app/AppMain.swift` | @main entry: AppKit bootstrap, synchronous run loop                                                                                           |
| `kinhin-app/AppDelegate/`  | Lifecycle + engine wiring + refresh; extensions for main menu, status item, fleet actions, engine reconfig                                    |
| `kinhin-app/UI/`           | `MainTabsWindowController` (per-tab extension files), `AlertKit`, and the setup repair runner                                                 |
| `kinhin-app/UI/SwiftUI/`   | SwiftUI forms: models (`@Observable`) + views for Connect, This Mac, Routing, Capacity, Toolchains, Containers, the wizard, Diagnostics, Logs |

Design documents live alongside this file, e.g. [runtime-abstraction-design.md](runtime-abstraction-design.md).

## Tests

`swift test` runs ~760 tests across three targets, all against fakes — no VMs or network required:

- **`KinhinKitTests`** (engine):
  - store, RPC, SSH, image pipeline, tart health, CLT probe, org permissions
  - queue attribution (queued and running, per repo)
  - token replacement (Keychain upsert, live engine swap, daemon RPC)
  - multi-forge (Gitea client, per-VM platform assignment, bootstrap, token-gated image provisioning)
  - runtime abstraction and routing (TartRuntime semantics, Apple-container runtime
    health/provision/exec/teardown, label pools, capacity partition, per-repo/per-workflow routing)
  - managed toolchains (catalog selection, no-implicit-install validation, managed-script content,
    shared-cache mounts at prepare and per runner VM, cache auto-expiry pruner)
  - config editing (runtimes/budget/labels editors: section upsert, comment preservation, validation gating)
  - hot reload (engine `applyReloaded`, daemon `reload_config` RPC), update check, setup-checklist
    parity, and setup UI presentation/layout
- **`KinhinCLITests`**: command routing table, starter-config auto-create policy, flag parsing,
  status rendering, the `config init` matrix, help text.
- **`KinhinAppTests`**: menu construction and presentation, status title/line and VM-section
  rendering, the tabbed main window (activation-policy and quit-on-close decisions, Fleet-tab
  status/VM rendering, launch-mode and login persistence, tab switching, delegate plumbing),
  update menu states, update preferences, setup repair execution.

## CI

`.github/workflows/ci.yml` lints, builds, and tests on a self-hosted macOS runner; `release.yml` publishes the DMG,
CLI zip, installer, and checksums to GitHub Releases on `v*` tags.
