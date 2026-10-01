# Plan: opt-in telemetry (post-beta)

Status: not started. Not part of `v0.0.1-beta-1`, which ships with no telemetry.

## Context

The beta says "no telemetry" in `docs/security.md` and the README. Add telemetry only if issue reports and release download counts cannot answer a concrete question. When added it must be **opt-in, off by default, minimal and inspectable**, and the first-run wizard asks once.

**Gate before building:** write down the specific question telemetry will answer and the number of users at which it becomes useful. If an issue template or download counts can answer it, don't build this.

## Decisions

- **Consent lives in `config.yaml`**, key `telemetry: on|off`, not UserDefaults. The CLI and daemon read the config but not the app's UserDefaults, so config is the only store all three surfaces share. A missing key means "not asked yet", which behaves as off.
- **Payload (allow-list only):** kinhin version, macOS major version, chip family, forge kinds in use (e.g. `github`), runtime kinds in use, coarse counters (jobs run, runner failures by error category, crashes), and a random install ID regenerated when the user toggles off then on. **Never:** repo, org or account names, hostnames, URLs, paths, tokens, stored IPs, job names or logs.
- **Transport:** one HTTPS POST per day (batched) to an endpoint you control, for example a small Cloudflare Worker with a counter store. No third-party SDK. Fail silently and never block or aggressively retry.
- **The docs must match the code.** The README and `docs/security.md` describe exactly what is sent, and a test enforces the field list (see Tests).

## Implementation steps

1. **KinhinKit core, `Sources/KinhinKit/Telemetry/`**
   - `TelemetryEvent`: a closed Codable struct with allow-list fields only (no free-form strings or dictionaries).
   - `TelemetrySink` protocol with a production `HTTPTelemetrySink` (takes an injected `URLSession?`, like `UpdateChecker`) and a no-op sink used whenever consent isn't `on`.
   - `TelemetryRecorder`: an actor (not a raw lock) that accumulates counters, flushes once a day and checks consent on every flush.
   - Wire counters from the fleet's job and runner lifecycle points. The engine only calls the recorder, so with the no-op sink nothing leaves the machine.
   - Put errors in an existing enum. Best-effort sends go through `bestEffortAsync` so failures are logged, and `CancellationError` propagates.
2. **Config key**
   - Add `telemetry` to `KinhinConfig` and its `default` (`Config/ConfigModel.swift`), to `PartialConfig` (`ConfigDTO.swift`), to parsing and validation in `ConfigLoader` (reject anything other than `on` or `off`), and to the commented starter in `ConfigTemplate.swift`.
   - Add a `Field.telemetry` case to `GeneralConfigEditor` (`keyPath(for:)` and `valueText(for:)`) and expose it in `GeneralConfigEditor.Snapshot`, so edits keep comments and go through `ConfigFileEdit.apply` re-validation.
3. **Wizard step**
   - Add `case telemetry` to `WizardModel.Step` (`Sources/kinhin-app/UI/SwiftUI/Wizard/WizardModel.swift`) between `toolchains` and `start`, plus a case in `WizardView.content`. The "Step N of count" header updates itself.
   - The step shows a short plain-language summary of what is and isn't collected, and a "Show exactly what would be sent" disclosure that renders a sample `TelemetryEvent` as JSON.
   - Two equal-weight choices, "Share anonymous usage" and "No thanks", **neither preselected**. Continue is enabled once one is chosen, and Skip counts as "No thanks".
   - The choice is written through `GeneralConfigEditor`. A failed write is shown in the form's status label.
   - Existing users upgrading with an unset key get a one-time, non-blocking prompt in the main window. Nobody who already chose is asked again.
4. **Settings and CLI**
   - App: a toggle in Advanced → App (`AppSectionModel` / `AppSectionView`) backed by the config key, with a "View what's sent" button.
   - CLI: `kinhin telemetry status|on|off|show`. Add a `CLICommand` case and `parse` branch (`Commands/CLICommand.swift`), a `switch` arm in `KinhinCLI.swift`, an entry in `HelpText.swift`, and `Commands/TelemetryCommand.swift`. `show` prints the exact payload that would be sent next, and must not auto-create a config file.
   - `KINHIN_TELEMETRY=off` and `DO_NOT_TRACK=1` force it off regardless of config.
5. **Doctor and docs**
   - Add a telemetry row to the doctor report as a new optional field on `DoctorReport` (additive, so the JSON stays stable) and to both renderers (`DoctorReport+Text.swift`, `DiagnosticsModel.swift`). It must not be a `SetupCheckResult`, since that would affect `ready`.
   - Rewrite the "Telemetry and network calls" section in `docs/security.md`, update the README banner, add a changelog entry, and keep `scripts/docs-lint.sh` clean.
6. **Server side** (separate repo or folder): a Worker that accepts only the schema above, drops IPs, stores daily aggregates, publishes a retention limit, and offers a delete-my-data path keyed by install ID.

## Tests

- **Payload allow-list:** encode a fully populated `TelemetryEvent` and assert the exact key set, so adding a field fails the build until the docs are updated. A second test feeds known secrets and names (a token, a repo name) through the recorder and asserts none appear in the JSON.
- **Consent gating:** with the key `off`, unset, or forced off by environment, the recorder never calls the sink (new `FakeTelemetrySink` in `Tests/KinhinTestSupport`). With `on`, it sends once per day.
- **Transport:** `StubProtocol` tests for success, 4xx and 5xx, and offline, asserting the engine is never blocked or failed by it.
- **Config:** `ConfigTests` and `GeneralConfigEditorTests` cases for the new key (round trip, invalid value rejected, comments preserved), plus `config validate`.
- **Wizard:** `WizardModelTests` for the new step (neither choice preselected, Continue disabled until chosen, skip means off, write failure surfaces), and `SettingsTabTests` for the toggle.
- **CLI and doctor:** `CLICommandTests` routing, `telemetry show` output, and the doctor row.
- Run `swift test` and `scripts/tsan.sh` (new actor and shared state).
