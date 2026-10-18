# Plan: The healing agent (on-device Apple Intelligence advisor)

> **Status:** Implemented on `feature/healing-agent`, not yet released. The rules, journal, CLI, RPC, MCP and app
> surfaces are built and unit-tested. The e2e suite has run the CLI (quick tier), the Gitea × Docker lanes and the live
> advisor lane; the Tart warm-VM lane is written but not run. The on-device advisor (Foundation Models) is in every build and
> answers on macOS 26+ with Apple Intelligence on. Section 7 lists where
> the build differs from the first draft of this plan.
> **User guide:** [../healing.md](../healing.md).

## 1. Goal

One place that sees the fleet's problems and fixes what it safely can, instead of a status line the user has to act on.
Safe, reversible fixes run on their own; destructive ones wait for approval; tokens are never handled. Apple
Intelligence (Foundation Models) advises on problems no rule covers, choosing only from an allowlist.

Out of scope: fixing failed CI jobs in users' repositories; free-form command execution.

## 2. Design

**The rules heal; the model only chooses.**

- `HealingSignal` normalizes a problem from the status alerts (`disk`, `account:*`, `queue:*`, `credentials`,
  `reconcile`), the records (a teardown that keeps failing), the spawn backoff (with the runtime's health probe as evidence) and the setup checklist (runtimes and images
  only; tart checks only when the fleet runs tart). Its `key` (kind + subject) identifies the problem across passes.
- `Remediation` is a closed enum whose kind fixes the tier (`automatic`, `approval`, `manual`). Every fix runs through
  an existing code path (`deleteVMRecord`, `retryDetachedForgesIfDue(ignoreBackoff:)`, `ToolchainCachePruner` plus
  `pruneProjectImages`, `ImagePrunePlan`, `RuntimeInstaller` and `HostAgentInstaller`, `TartHealthProbe.repairs`,
  `AppleContainerRuntime.startSystem`). Manual kinds (`replace_token`, `prepare_image`, `inspect_instance`,
  `review_setup`) only produce instructions; `perform` refuses them.
- `HealingPlaybook` maps a signal to ordered fixes, a minimum age (a one-off failure heals by itself: 1 min for a
  detached account, 2 min for an unreadable queue or a failing reconcile pass, 10 min for a stuck teardown) and the
  advisor's candidates. Pure, so every rule is unit-tested.
- `HealingBudget` caps tries per (problem, fix) at `max_attempts` with a 2-minute cooldown; a fix that "succeeded" but
  left the problem in place is spent at once.
- `HealingAgent` runs its own loop (not the reconcile pass, so a slow model or a long install never delays scaling),
  keeps the `HealingJournal` (bounded, persisted owner-only next to `fleet.json`; open entries expire on restart), and
  publishes `FleetStatus.healing` plus a `healing` alert while approvals are pending.
- `HealingHostActions` holds the side effects outside the engine, so engine tests never run Homebrew; production wiring
  passes `.live`.
- `HealingAdvisor` is the seam for the model. `FoundationModelsHealingAdvisor` makes one structured generation with a
  `DynamicGenerationSchema` whose `remediation` field is limited to the candidates' ids plus `none`, followed by
  `confident` and a one-sentence `explanation`, under one 20-second deadline. The agent re-checks the pick: outside the candidates, ignored; approval tier, still pending; not confident,
  surfaced. Credentials and setup problems have no candidates.

## 3. Foundation Models, not siri-ai

The first build reached the model through siri-ai (RabinApps/siri-ai), whose custom decisions are a thin layer over
Foundation Models. siri-ai declared macOS 26 and tools 6.4, so kinhin (macOS 15, tools 6.2) could only link it behind a
build-time opt-in, and releases would have run without an advisor until siri-ai tagged a macOS 15 release. kinhin now
calls Foundation Models directly: it imports under `#if canImport(FoundationModels)` (the Xcode 26 SDK kinhin already
requires), answers only behind `#available(macOS 26, *)`, and the framework is weak-linked (the release binary's
minimum stays macOS 15.0). One generation now returns the pick and its reasoning together, so the explanation is the
reasoning behind the pick rather than a second, separate answer.

## 4. Surfaces

- CLI: `kinhin heal [--json]`, `heal approve ID`, `heal dismiss ID` (exit 0 / 1 by what waits on the user).
- RPC: `healing_status`, `healing_approve`, `healing_dismiss` (the last two are serialized with other fleet mutations).
- MCP: `heal_status`, read-only.
- App: the Healing card in Diagnostics (approve, dismiss, history), a notification when a fix succeeds.
- Config: `healing: {enabled, auto: safe|none, ai: auto|off|ollama, max_attempts, ollama: {model, fast_model, host}}`.
  The Ollama advisor is a cascade (System 1 decision model, then the LLM); see [ollama-healing-advisor.md](ollama-healing-advisor.md).
- Debug-only switches for the e2e suite: `KINHIN_HEALING_TIMINGS=fast`,
  `KINHIN_HEALING_ADVISOR=stub:<kind>|stub:invalid|stub:doubtful:<kind>`. Both are read under `#if DEBUG`; release
  builds never read them.

## 5. Verification

- Unit: `HealingPlaybookTests`, `HealingBudgetTests`, `HealingJournalTests`, `HealingAgentTests` (tiers, budget,
  escalation, every advisor guardrail), `FleetEngineHealingTests` (signals from records, alerts, backoff and setup checks;
  fixes; approval through the engine), `HealingConfigTests`, `HealCommandTests`, the app's healing tests, and
  `FoundationModelsHealingAdvisorTests` (prompt, schema, deadline; one live call with `KINHIN_LIVE_AI=1`).
- E2E: `HealingCLITests` (quick tier) and `HealingTests` (Docker lanes; the Tart warm-VM lane; the live advisor lane with
  `KINHIN_E2E_AI=1`). See [../e2e-testing.md](../e2e-testing.md).

## 6. Open questions

- Approval has no second confirmation in the app; the button is the approval.
- The advisor's explanation is display-only and can be wrong about the cause (seen live with the earlier two-call
  design: it blamed authentication for a 503). It never drives an action.

## 7. Where the build differs from the first draft

- **No automatic teardown retry.** The draft had a `retryTeardown` fix for a stuck teardown. Teardown retries stay with
  the engine, which already makes them; a teardown still failing after 10 minutes is now the manual
  `inspect_instance` fix, which tells the user how to remove the instance with its runtime and then run
  `kinhin cleanup --vms`.
- **Vanished warm VMs are the engine's.** The draft had the agent scan records with no lifecycle. The engine's orphan
  sweep now does it (`sweepUnwatchedRecords`, one `Runtime.states(of:)` listing per runtime), so it works with healing
  off; `HealingAgent.note` journals each removal.
- **Review fixes.** A forge re-attach goes through the engine's single-flight retry slot (`retryDetachedForgesNow`); a
  stopped agent writes nothing and a launching one re-reads the journal, so engines replacing each other never clobber
  it; approved fixes are tracked and cancelled on stop; an advisor fix that left the problem in place is surfaced once;
  the advisor's availability is checked before publishing; status polls carry only open entries and recent history; the
  setup checklist re-runs only while it matters.
- **Its own loop.** The draft ran the agent inside `reconcileOnce`. It now runs its own 30-second loop (started with
  the engine, stopped with it and on a config rebuild), so a slow model or a long install never delays scaling, and the
  agent's lock is a leaf that is never held across an `await`.
- **Tart checks only for Tart fleets.** Setup checks about tart and its images (`tart`, `tart-rollback`, `image`,
  `base-image`) only become signals when the fleet can run Tart VMs (`FleetEngine.tartInUse`), so a Docker-only fleet
  is never told to install tart. Config, Command Line Tools and architecture checks are never signals.
- **Foundation Models directly.** The draft linked siri-ai; the advisor now calls Foundation Models itself (section 3),
  so every build has it and no `Package.swift` opt-in or separate scratch path is needed.
