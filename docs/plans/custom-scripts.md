# Plan: Custom scripts (a `script` forge with multiple scripts, schedules, guides and examples)

> **Status:** Not implemented. Design drafted from reading the engine; nothing here has been built or run.
> **Inspiration:** Cilicon's `script` provisioner (boot a fresh VM, SSH in, run a script, tear down). kinhin adds queue-driven
> scaling, resource caps, every runtime, and, in later phases, named scripts and cron schedules.

## 1. Goal

Let people run their own scripts in fresh, isolated kinhin instances without a supported forge: nightly jobs, a home-grown
queue, a Jenkins or Drone poll, a one-off task. An instance boots (Tart VM, apple/container, Docker, or host), runs the
script, and is deleted when the script exits. kinhin keeps what it already does well: it caps instances to what the Mac can
hold, routes by runtime, redacts logs and cleans up.

Non-goals: a CI server, a pipeline language, artifacts, secrets management, or a replacement for `launchd` on the host.

## 2. How it fits the code today

- A forge is an `accounts:` entry with one `ForgeDescriptor` (`Sources/KinhinKit/Forges/Forge/ForgeDescriptor.swift`, single
  exhaustive switch in `ForgeID.descriptor`) and a `Forge` adapter. Buildkite (`Forges/Buildkit/`) is the closest template.
  `docs/adding-a-forge.md` is the checklist.
- `Runtime` (`Runtimes/Runtime.swift`) is forge-agnostic. `execRegistration(id, ip, script, timeout) -> ShellResult` already
  runs a script inside an instance over SSH (Tart) or exec (container, Docker, host), so a user script is a registration
  script that runs to completion.
- The engine decides an instance is finished from the forge's runner list (`FleetLifecycle.awaitRunnerExit`, with
  `ForgeExitSemantics.deregisters` and `.idleGrace`). A script has no runner on a server, so it needs a third semantic,
  **script exit**, where the engine runs the script itself.
- Demand comes from `Forge.queuedJobs()`, then `ForgeDemand` and `Autoscaler`, with `SpawnBackoff` as a guard.
- The model is token-centric: Keychain account `<raw>-pat`, `kinhin auth`, `TokenHealthCheck`, wizard pickers over
  `ForgeID.allCases`, agent bake and host install. A token-less, agent-less forge needs an explicit `usesToken` flag so those
  paths skip it. **This is the main risk.** Phase 0 is a compile spike to list every site.

## 3. Config design

Phase 1 shape (one script per account):

```yaml
accounts:
  - name: nightly
    forge: script
    scope: nightly                 # free-form name for status and routing; no network meaning
    labels: [kinhin-script]        # pool and route selection, as for other forges
    script:
      run: |
        ./ci.sh
      demand_command: "./queue-depth.sh"   # optional, runs on the HOST; prints N or {"queued": N}
      demand_interval: 15
      instances: 1                 # used when no demand_command: keep N running (Cilicon-style loop)
      timeout: 3600
      env: { APP_ENV: ci }
```

Phase 2 and 3 shape (several named scripts, some scheduled):

```yaml
accounts:
  - name: ops
    forge: script
    scope: ops
    labels: [kinhin-script]
    scripts:
      - name: nightly-build
        schedule: "0 2 * * *"          # cron, 5 fields, in `timezone`
        timezone: "America/New_York"
        on_overlap: skip               # skip | queue | allow
        on_missed: run_once            # skip | run_once (daemon was down at the scheduled time)
        run: ./build.sh
        timeout: 7200
        runtime: tart                  # optional per-script runtime and image
        image: tahoe-xcode
      - name: drain-queue
        demand_command: "./depth.sh"
        max_instances: 2               # per-script cap, under the fleet cap
        run: ./worker.sh
      - name: cleanup
        schedule: "*/30 * * * *"
        run: ./cleanup.sh
```

Environment for every script: `KINHIN_INSTANCE`, `KINHIN_ACCOUNT`, `KINHIN_SCRIPT`, `KINHIN_RUNTIME`, `KINHIN_RUN_ID`,
`KINHIN_TRIGGER` (`demand`, `schedule`, `manual`), plus the `env:` map. `runners_per_vm` is forced to 1.

Rules (decide before building, record the outcome here):

- A script account must set either `demand_command`, `schedule`, or `instances`. Combining is allowed per named script.
- `demand_command` failure means "unknown, keep the current fleet", never "scale to zero" (same rule as forge outages).
- The script must consume or mark its work item, or demand never drops and kinhin respawns (with `SpawnBackoff`).
- `env:` holds plain values only; warn against secrets. A Keychain-backed `env_secret:` is a possible later phase.

## 4. Phases

**Phase 0, spike (small, throwaway branch).** Add `ForgeID.script`, `ScriptDescriptor`, `usesToken`. Let `swift build` list the
exhaustive sites. Decide whether `ForgeID.script` stays a forge or becomes a separate top-level `scripts:` concept that
reuses a `Forge` adapter internally. Record the decision here.

**Phase 1, one script per account with demand.**
Config DTO and `parseScriptAccount` (strict: env key charset, bounds). `ScriptForge`: registration `.none`, exit semantics
`.scriptExit`, `queuedJobs()` via `demand_command` (argv-safe `Process`, timeout, output cap, int or JSON), `instances`
fallback. Engine `awaitScriptExit` beside `awaitRunnerExit`: wrapper script (`set -eo pipefail`, env, script written to a
`umask 077` file, nothing in `ps`), run via `runtime.execRegistration` with the timeout, record exit code and output tail,
redact via `LogRedactor`, then `deleteVMRecord`. Failure and timeout are marked but the instance is still deleted. Skip the
token-mint gate. All four runtimes; host keeps its explicit consent; Linux containers need `bash`.

**Phase 2, multiple named scripts.**
`scripts:` list under one account, per-script `run`, `env`, `timeout`, optional `runtime` and `image` (reuses
`RuntimeRouting` and `ImageRouting`), per-script `max_instances` under the fleet cap, per-script status rows. Demand and
platform assignment (`ForgeDemand.assignAccount`) must become per-script, so the autoscaler needs a sub-account key. Fair
sharing between scripts uses the existing unmet-demand rule.

**Phase 3, cron schedules.**
A scheduler inside the daemon: parse 5-field cron (write a small, tested parser; no new dependency), honor `timezone`,
persist `last_fired` in `FleetStore` so a restart does not double-fire, `on_overlap` (`skip`, `queue`, `allow`) and `on_missed`
(`skip`, `run_once`) policies, DST handling (spring-forward skip, fall-back single fire), jitter-free. A schedule produces one
unit of demand with `KINHIN_TRIGGER=schedule`. Cron does not fire while the fleet is paused; resume applies `on_missed`.

**Phase 4, operating it.**
`kinhin script list`, `kinhin script run <name>` (manual trigger, `KINHIN_TRIGGER=manual`), `kinhin script history <name>`
(last runs, exit codes, duration, output tail), `--json` for each. App: a Scripts section in the Fleet tab showing next fire
time, last result and a Run now button (config stays edited by hand). Output tail retention bounded and redacted.

**Phase 5, guides and examples.**
`docs/script-runner.md` (concepts, config reference, the work-item rule, cron cheat sheet, host-mode warning, troubleshooting),
plus copy-paste examples under `docs/examples/scripts/` (each a full `config.yml` snippet and the script it calls, each
tested in a real run before it is published):

- nightly macOS build and test on a Tart VM at 02:00
- drain a file-backed queue (the smallest demand example, also used in the manual test)
- poll a Jenkins or Drone queue and run one worker per waiting job
- scheduled cleanup or maintenance every 30 minutes
- a Cilicon-style loop: keep one fresh VM running a long script
- run a script in an apple/container Linux instance
- a webhook-style trigger using `kinhin script run` from another tool

Add a short "Custom scripts" section to `docs/forges.md` (marked untested until run), update `docs/compare.md` (the Cilicon
and kinhin lines and the "what kinhin is missing" list), `docs/runtimes.md`, `docs/security.md`, `docs/beta-roadmap.md`,
`CHANGELOG.md`, README forge lists, the website sidebar, and every other list from section H of `docs/adding-a-forge.md`.

## 5. Security notes to put in the docs

The script and `demand_command` run with your privileges and come from your own config, like a shell script. In `host`
mode the script runs on the Mac with no isolation and keeps the existing consent flag. `env:` values are not secrets. Logs go
through `LogRedactor`. Cron plus `on_overlap: allow` can exhaust the capacity cap, which is the intended protection.

## 6. Testing and honesty

- Unit tests in all three targets: config validation, cron parsing and DST cases, `demand_command` parsing and failure, wrapper
  quoting and secret handling, `awaitScriptExit` (success, non-zero, timeout, dead instance, cancellation), overlap and missed
  policies, multi-script fairness, CLI `--json`. New globals use `Mutex`. Run `scripts/tsan.sh` (new watcher and scheduler state).
- Each phase ships as **untested** in `docs/forges.md` until run for real on a Tart macOS VM and apple/container, recorded in
  `docs/plans/beta-test-log.md`. Docker and host stay unit-tested only until run. Examples are published only after a real run.
- Known v1 limits to state: no live output streaming (see `docs/plans/local-live-output.md`), no retries, no artifacts, no
  secrets store, no dependencies between scripts.

## 7. Open questions

- Stay a forge (`forge: script`) or a separate `scripts:` section? Decide in Phase 0.
- Is a built-in cron worth it versus triggering `kinhin script run` from `launchd`? (Built-in survives sleep/restart handling
  and respects pause and the fleet cap, which `launchd` cannot.)
- Should a script be able to request a specific image or label per run, and how does that interact with per-project toolchains?
- Should a failed scheduled run alert (menu bar notification) in v1 of Phase 4?
