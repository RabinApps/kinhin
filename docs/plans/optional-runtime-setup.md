# Plan: optional runtime setup, PR isolation, and wizard capacity

## 1. Extend the release installer with optional runtime choices

- Keep the installer’s existing verified DMG, app, and CLI installation behavior intact.
- After installing kinhin, offer optional Tart, Apple container, and Docker setup using a terminal prompt that reads from `/dev/tty` (so `curl | bash` continues to work). Preselect Tart as requested, but allow changing the selection or skipping runtime setup entirely. If there is no interactive terminal, skip prompts and leave setup to the wizard rather than hang or guess.
- Reuse the installed CLI’s `kinhin setup repair` runtime commands, which share the app’s `RuntimeInstaller` options and host checks. If a selected runtime cannot be installed (for example, Homebrew is missing), explain the failure and leave the already-installed app usable; do not silently elevate or roll back the app.
- Ask whether this installation will serve contributor/fork PRs. Persist only that yes/no answer as a one-time, versioned onboarding handoff under kinhin’s Application Support directory. The wizard consumes it once; it does not edit `config.yaml` or count as consent to privileged setup. With no answer available, the wizard asks normally.
- Update installer usage/help and installation documentation. Reconcile wording that currently describes Apple container as the fresh-install default with the newly requested Tart installer preselection, while keeping runtime trade-offs clear.

## 2. Add explicit, secure Softnet setup to first-run onboarding

- Use the handoff (or ask in the wizard) to establish whether untrusted contributor/fork PRs are expected. Explain that Softnet isolates Tart VMs, not Docker or Apple-container jobs, and recommend it when Tart will run untrusted code.
- When applicable, offer to install Softnet and configure Tart isolation. A positive PR answer may preselect/recommend this path, but the wizard must obtain a separate, clear user confirmation before installing/configuring it. Do not turn on `tart_softnet` unless the full setup succeeds.
- Add a narrowly scoped privileged helper for the exact Softnet ownership/mode operation, with no arbitrary command or path execution. Package and sign it as a root LaunchDaemon/helper using the project’s supported macOS service-management flow; require the native macOS approval flow and handle cancellation, approval-required, and errors explicitly. Validate the resolved Softnet binary path and verify the resulting ownership/mode before reporting success.
- If setup is declined, unavailable, or fails, leave isolation off, surface the security limitation in the wizard, and preserve the existing doctor/readiness behavior. Never claim that Softnet is protecting jobs unless it is configured and available.
- Update the app bundle/release packaging and signing path to include the helper and its service definition. Document setup, upgrade/reinstallation expectations, cancellation/failure behavior, and the Tart-only scope in the runtime/security guides.

## 3. Add a Capacity step before Toolchains

- Insert a dedicated Capacity step between “Get this Mac ready” and Toolchains; update step numbering, navigation, header/subtitle, and wizard summaries/tests.
- Read and edit the existing `max_runners` and `runners_per_vm` settings through the established config editor. Label the first control according to the selected runtime (VMs for Tart; instances/slots for container runtimes) so it does not promise VMs where none are used.
- Show the configured concurrent job-slot ceiling (`instance cap × runners_per_vm`) and a live, clearly identified host-capacity estimate using existing host/resource and capacity calculations. Explain that actual concurrency can be lower because CPU, RAM, disk, runtime, and routing limits bind; do not present the configured total as a guaranteed throughput promise.
- Initialize controls from the saved config, respect current validation bounds and existing min/max constraints, persist changes through the config editor with visible errors, and leave unrelated capacity settings untouched.
- Add focused tests for config round-trips/validation, slot arithmetic and estimate messaging, step order/navigation, handoff consumption, and Softnet opt-in/cancellation/failure. Add tests for installer prompt/handoff behavior that do not invoke real Homebrew or privileged operations, and unit-test helper validation separately from real system authorization.

## 4. Verify and document

- Update the relevant runtime, security, install, and capacity docs as needed; keep code-derived documentation blocks generated rather than hand-edited.
- In build mode, run `swift build`, `swift test`, and `swift format lint --strict -r Sources Tests`. For documentation changes, also run `bash scripts/docs-lint.sh`, `bash scripts/docs-sync.sh`, and `cd website && npx vitepress build`.
- Review changes against the shared checkout carefully and leave unrelated existing work untouched.
