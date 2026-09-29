# Orchard compat sunset

kinhin 0.1.0 shipped the Orchard → kinhin rename with a compat layer so no pre-rename user
loses data, config, tokens, or a running fleet. This plan retires that layer deliberately:
each surface first warns (naming the release that will drop it), then is removed in its own
commit. The orchard allowlist in `scripts/docs-lint.sh` doubles as the checklist — removing a
surface means deleting its allowlist entry in the same commit, and the lint then blocks
reintroduction. This document is itself allowlisted: it must be able to name the identifiers.

[← Back to README](../README.md)

## Principles

- **Never destroy data silently.** Removal order follows cost of premature removal: conveniences
  first, tokens later, the on-disk config move last.
- **Warn before removing.** Every surface gains a `Log.warn` (or `Log.info`, where the message
  reports an action succeeding) that names the release which will drop it. The phrase is stable
  and pinned by a test, so a release grep can audit it.
- **One removal, one commit.** Each removal deletes the code path, its tests, the matching
  bullet in [the migrating guide](../website/guide/migrating.md), and the allowlist entry —
  together, with `swift test` and `bash scripts/docs-lint.sh` green.
- **Release-count gates, not dates.** A surface is removed only after its warning has shipped
  in one full release. The versions below are proposals to shift with the actual cadence
  (current: 0.1.0).
- **Forward-only.** Nothing is re-added. A user who arrives after removal follows the manual
  steps that remain in the migrating guide.

## Schedule

| Surface (allowlisted file)             | Legacy identifier         | Warns | Removed | Why this order                                              |
| -------------------------------------- | ------------------------- | ----- | ------- | ----------------------------------------------------------- |
| `UpdatePreferences.swift`              | `ORCHARD_UPDATE_REPO`     | 0.2.0 | 0.3.0   | Pure convenience; nothing is stored                          |
| `Daemon.swift`                         | `com.orchard.daemon` plist| 0.2.0 | 0.3.0   | Uninstall-only cleanup of a daemon that cannot survive the rename's release boundary |
| `install.sh` (not swept)               | `Orchard.app` + symlinks  | —     | 0.3.0   | Same wave as the LaunchAgent; installer output already names the legacy app |
| `FleetReconcile.swift`                 | `orchard-` VM-name prefix | 0.2.0 | 0.4.0   | A suspended pre-rename VM can outlive the rename by months   |
| `TokenStore.swift`                     | `com.orchard.runner` item | 0.2.0 | 0.4.0   | Re-creatable with one `kinhin auth set`; the legacy item is left in place, so removal is annoyance, not loss |
| `ConfigTemplate.swift`                 | upgrader greeting comment | 0.2.0 | 0.5.0   | Targets the same audience as the directory move              |
| `Paths.swift`                          | `Application Support/Orchard/` move | 0.2.0 | 0.5.0 | The only surface whose removal can orphan hand-edited config; goes last |
| `website/guide/migrating.md`           | the guide itself          | —     | 0.5.0   | Shrinks to a changelog note once every mechanism above is gone |

## Deprecation log lines

Exact strings for the 0.2.0 warning commit; keep them verbatim so tests can pin them.

- `UpdatePreferences.repo(fromEnvironment:)` (called from the daily update check), only when the
  legacy variable is the one honored:
  `Log.warn("app", "ORCHARD_UPDATE_REPO is set; use KINHIN_UPDATE_REPO instead — the legacy variable will be ignored in kinhin 0.3.0")`
- `Daemon.uninstall`, after removing the legacy plist (informational — the action succeeded):
  `Log.info("daemon", "removed legacy com.orchard.daemon LaunchAgent; legacy cleanup will be removed in kinhin 0.3.0")`
- `FleetReconcile`, next to the existing adopt line, when the name carries the legacy prefix:
  `Log.warn("engine", "adopting pre-rename orchard- VM; pre-rename instance names will be ignored in kinhin 0.4.0")`
- `TokenStore`, when a read falls back to the legacy Keychain item:
  `Log.warn("keychain", "token found under the legacy Orchard item; re-save it with kinhin auth set — legacy migration will be removed in kinhin 0.4.0")`
- `Paths.migrateLegacySupportDirectory`, whenever the legacy directory still exists (after a
  successful move it is gone, so the warning stops on its own):
  `Log.warn("paths", "legacy Orchard/ support directory found; the automatic move to Kinhin/ will be removed in kinhin 0.5.0")`
- The config template greeting gains a matching comment: "the automatic migration is removed in
  kinhin 0.5.0 — move the directory by hand if you still need it."

## Removal mechanics

For each wave (0.3.0, 0.4.0, 0.5.0), the commit that removes a surface:

1. Deletes the code path and its tests (`StoreAndLogTests`, `UpdateMenuTests`,
   `ErrorHandlingTests`, `HostRuntimeTests`' legacy fixtures — whichever apply).
2. Deletes the deprecation log line and its pin.
3. Updates `website/guide/migrating.md` (and the CLI help text if it mentions the surface).
4. Removes the file from `orchardAllowlist` in `scripts/docs-lint.sh` — the lint then fails on
   any future reintroduction.
5. Appends a line to the release notes: "Orchard compat: <surface> removed as warned in 0.2.0."

After the 0.5.0 wave the allowlist holds only this document, and the migrating guide is a
changelog note.
