# Kinhin architecture review and cleanup plan

> **Status:** being implemented phase by phase, one commit per phase.

## Context
You asked for a review of the whole app: whether the architecture makes sense, what can be cleaned up, and what could be better. I reviewed the three targets (`KinhinKit`, `kinhin`, `kinhin-app`) plus the tests, docs and CI. I checked the P0 bugs below against the source myself.

**Verdict:** the overall shape is sound.
- The engine lives in Kit, and there's one `Forge` protocol and one `Runtime` protocol.
- The UI is SwiftUI forms driven by `@Observable` models, and the App Intents go through a test seam.
- Hygiene is good: no `try!`, `as!`, `print`, `DispatchQueue` or `NSLock`, and no file is over about 400 lines.

The problems are in the seams. There are several real bugs; business logic is copied between the CLI, the app and Kit, and the copies have already drifted apart; `FleetEngine` and `AppDelegate` have picked up too much; and the docs are stale.

The work is split into phases. Every phase ends with `swift build`, `swift test` and `swift format lint --strict -r Sources Tests`. Mechanical commits are kept separate from behavior commits, as CLAUDE.md requires.

---

## Phase 1: Correctness bugs (each fix comes with a test that reproduces it first)

1. **Primary GitHub forge is stored under two keys.**
   - `FleetEngine.init` stores it under `primary.name` (`Fleet/FleetEngine.swift:163`).
   - The convenience init (`:333`) and `replaceCredentials` (`Fleet/FleetEngine+Credentials.swift:24`) store it under `"github"`.
   - When the primary account is named e.g. `work`, a stale `"github"` forge gets polled. Token rotation then misses the real forge, and `registrationCache(for:)` only special-cases `"github"` (`FleetEngine+Accounts.swift:18`).
   - Fix: key by `primary.name` everywhere.
2. **`deleteVMRecord` cancels its own lifecycle task** (`Fleet/FleetLifecycle.swift:286`). When it's called from `awaitGiteaExit` or `awaitEphemeralExit`, the runner-deregistration calls that follow fail with cancellation. `bestEffortAsync` then swallows that without a log. The result is Gitea runners that stay registered after the VM is gone.
   - Fix: skip the cancel when running inside that task (pass a flag from the lifecycle callers), or run the cleanup in an unstructured task.
3. **Concurrent `reload_config` RPCs race** (`Fleet/Daemon.swift:216-250`). Two rebuilds can each detach the same engine and launch a replacement, which leaves an orphan engine running. Separately, `detachKeepingInstances` cancels `reconcileTask` but never awaits it (`FleetEngine+Reload.swift:36`).
   - Fix: serialize rebuilds with a Mutex-held "rebuilding" flag or a small actor, and await the reconcile task.
   - Also: the `engine.status()` call at `Daemon.swift:220-221` is made twice and should be one call.
4. **`GeneralConfigEditor.replace(.baseImage(nil))`** (`Config/GeneralConfigEditor.swift:130-137`) removes the first `base_image:` line at any indentation. That can delete `container:` or `docker:`'s `base_image` instead of the top-level one. Fix: match only the top-level key, reusing the existing `isTopKey` helper.
5. **`kinhin auth status --forgejo` checks the Gitea account.** It sets `giteaMode` and then reads `cfg.gitea` (`kinhin/Commands/AuthCommand.swift:230, 335`). Fix: pick `cfg.forgejo` when `forge == .forgejo`.
6. **Two "Prepare image" buttons ignore `base_image:`.**
   - The buttons: `MacToolsModel.prepareImage` (`UI/SwiftUI/MacTools/MacToolsModel.swift:286`) and `SetupRepairRunner.prepareImage` (`UI/SetupRepairRunner.swift:110`).
   - They never set `options.source`, unlike `ToolchainsModel` and the CLI.
   - Fixed for good by Phase 3's `ImageBuildService`; patch the buttons directly first if Phase 3 is deferred.
7. **Shortcuts report success when the daemon fails.** In daemon mode, `performFleetAction` and `performVMDelete` go through `sendDaemonCommand`, which shows an alert and swallows the error (`AppDelegate/AppDelegate+FleetActions.swift:13-19, 55, 139`). Fix: the intent path should throw.
8. **Connect-card account ownership.**
   - `ForgeConnectionModel.configuredAccount` picks the first account of a forge, but `commit()` writes by forge name.
   - `AccountsModel.reload` doesn't exclude the card-owned accounts, so they show up twice.
   - Fix: both should use the same "primary account" rule as `KinhinConfig.primaryGitHub`/`forgeView`.

## Phase 2: RPC and main-thread safety
- **`RPCClient.send` is blocking socket I/O with a 60s default timeout.** It's called on the MainActor from `AppDelegate.refresh()` every 3s, and from fleet actions, token rotation and config push. A hung daemon therefore freezes the app.
  - Add an `async` wrapper that runs the blocking call off the main actor, e.g. `Task.detached` or a nonisolated async func.
  - Add typed helpers such as `status() async throws -> FleetStatus`. That removes 4 copies of the decode (`AppDelegate.swift:214`, `+FleetActions.swift:103`, `kinhin/Commands/RunCommands.swift`).
  - Make `replace*`/`reloadConfig` return `Void` instead of an always-true `Bool`.
- **`RPCServer.handleConnection`** (`Fleet/RPCServer.swift:66, 154`) does a blocking `availableData` read inside a cooperative `Task`, with no read timeout. Stuck clients can starve the pool.
  - Fix: read the request line on a dedicated thread (like the accept thread) with an `SO_RCVTIMEO`, then hop into a Task only for the handler.

## Phase 3: Consolidate duplicated logic into KinhinKit (the drift already causes bugs)
- **Capacity caps.** There are 4 copies, and they disagree: `FleetEngine.swift:259`, `FleetEngine+Reload.swift:124`, `Runtimes/RuntimesPaneViewModel.swift:108`, `Config/BudgetEditor.swift:102`. Merge them into a single `RuntimeCapacity.caps(for:host:)` in `Runtimes/`, so the UI preview matches what the engine enforces.
- **`ImageBuildService`** (Kit `Images/`) replaces 4 image-build paths: SetupRepairRunner, ToolchainsModel, MacToolsModel, `ImageCommand`. It also moves `startContainerSystem` out of UI code.
- **`FleetStatus` formatter** (Kit) to replace the 4 status-line/VM-row renderers: `AppDelegate+StatusItem.swift:115`, CLI `Shared.swift:261`, `Intents/FleetSummary.swift`, `FleetModel.detail`.
- **`FleetEngine.make(config:)` factory** to replace 3 engine-construction copies: `AppDelegate.swift:151`, `+EngineReconfig.swift:91`, `Shared.swift:249`.
- **Credential rotation.** The CLI's `notifyDaemon*` ×4 (`Shared.swift:19-60`) and the app's `+TokenReplacement.swift` currently route Gitea differently. Replace both with one `CredentialRotation.replace(forge:account:token:via:)`.
- **Token verification.** Replace 3 per-forge verify switches (`AccountsModel.liveVerify`, `ForgeConnectionModel.verifyAfterConnect`/`listRepos`, `AuthCommand` status) with one `ForgeClientFactory.verify(account:token:)`. This also absorbs dead `ForgeFactory` (see Phase 5).
- **`kinhin doctor` text mode** should render `DoctorReportBuilder`'s report, like `--json`, Diagnostics and the Intent already do. Today it re-probes everything, with six `try? ConfigLoader.load()` calls (`kinhin/Commands/DoctorCommand.swift`).

## Phase 4: Structural simplification
- **Forges**
  - Merge `ForgejoForge` into `GiteaForge`, parameterised by `ForgeID`; today it's a line-for-line copy.
  - Extract a `ForgeHTTP` transport covering session setup, status→error mapping, `isTransient` and `withTransientRetry`, and use it in the GitHub, Gitea and GitLab clients.
  - Fix GitHub's catch-all that turns `CancellationError` into `.http(0)` (`Forges/GitHubClient.swift:188`).
  - Merge `awaitGiteaExit` and `awaitEphemeralExit` (they're about 80% the same).
- **Runtimes**
  - Extract a shared `LinuxContainerCLIRuntime` (a CLI "dialect" struct) from `DockerRuntime` and `AppleContainerRuntime`, which share about 200 lines.
  - Also share the cache-prefix helper (3 copies) and the Tart install hint (4 copies).
  - Delete `Runtime.watchExit`: it's never called and every implementation is a no-op.
  - Check exit status on `run` in provision/teardown instead of `_ =`.
  - Make `existingInstanceIDs` and `containerIDs` throw on failure instead of returning `[]`.
- **Config editors.** Add a `ConfigFileEdit.apply(url:) { yaml in … }` core (read → edit → `ConfigLoader.parse` → write) plus a `YAMLTextSurgery` type holding `isTopKey`, `quote` and blank-line trimming. The editors to move onto it: General, Labels, Runtimes, Toolchains, Accounts, `ConfigEditor.save`. Make their error cases consistent.
- **FleetEngine state**
  - Keep `runtimesByRuntime` and drop the 5 separate runtime fields.
  - Move the injected collaborators (`tokenLoader`, `hostProbe`, `githubFactory`, drain timeout) into one immutable `Dependencies` struct.
  - Drop the legacy `githubAuth`/`github`/`registrationTokens` path in favour of per-account registration caches.
  - Keep one source of truth for running/paused.
  - Split `reconcileOnce` (~200 lines) into its steps.
  - Rename `VMRecord.poolLabels`: it holds a runtime id.
- **App state layer.** Add a `@MainActor @Observable FleetController`:
  - It sits behind a `FleetBackend` protocol with in-process and RPC implementations.
  - It owns status, the pending action, setup-incomplete and update state.
  - `FleetModel`, `AppSectionModel`, the menu and `AppFleetIntentBridge` observe it directly, instead of `AppDelegate` pushing copies around and the bridge doing an `NSApp.delegate as?` cast.
  - This removes the "engine or client" branch that's repeated in 8 methods, the duplicate `PendingAction` enum, and the write-only `MainTabsWindowController.lastStatus`.
- **Form models.** Share a `ConfigFormContext` (URL, one `onChanged` callback name, `write { } -> StatusLine`) and a `KeychainProbe` helper.
  - The forms that use `snapshotOrLog` (MacTools, Connect, ForgeConnection, Toolchains) should show a config parse error instead of rendering defaults, per CLAUDE.md.
  - Models should not present modals themselves (MacTools, Toolchains, `RuntimesModel+YAML`).
- **CLI.**
  - Split `kinhin/Commands/Shared.swift` into `CLIExit`, `Output`, `HelpText`, `Flags` and `ConfigCommands`.
  - Break `AuthCommand.run` into set/status/clear, with one config-lookup helper.
- **Daemon.swift.** Split it into dispatch and `LaunchAgent` plist install.
- **Main window, optional.** Make the tab bar a SwiftUI `TabView` root, which would remove about 300 lines of AppKit tab plumbing. Lower priority.

## Phase 5: Dead code and convention cleanup (mechanical commits)
- **Delete:**
  - `FleetEngine.initialForges`
  - `Forges/ForgeFactory.swift`
  - `VMPlatform`
  - `runTelemetryIfPossible` and its call site
  - `DaemonError.configProblem`
  - `runTartRepairIfNeeded` and the `SetupRepairRunner` instance methods reachable only from it, plus `RepairProgress` if it becomes unused
  - `replaceTokenClicked` / `openTokenSettings(focusing:)`
  - `AppDelegate.confirmOverride`
  - `MainTabsWindowController.lastStatus`
  - the orphan comment at `AppleContainerRuntime.swift:238`
  - the empty `ProvisionScriptFixtures`
  - the duplicate `NSSetUncaughtExceptionHandler` (`AppMain.swift:33` vs `AppDelegate.swift:69`)
- **Delete or move `SetupViewModel`/`SetupRowViewModel`/`SetupWindowLayout`.** They're only used by tests and carry `CGFloat` UI layout into Kit. Confirm they're unused first; if so, delete them along with their tests.
- **Replace `nonisolated(unsafe)` with `Mutex`:**
  - `TartBaseImage.digestResolver`
  - `KeychainTokenStore.serviceOverride`
  - `UpdateCheckTests.progressReports` (a TSan candidate)
  - Also remove the last `@unchecked Sendable` (`BaseImagePickerTests.FakeResolver`).
- **`try?` without a comment:** about 11 in Kit, plus the app and CLI ones. Either comment them or propagate the error. `try? await Task.sleep` must not swallow cancellation (`+EngineReconfig.swift:17`, `RunCommands.swift:131`).
- **Error enums.**
  - Fold `AccountAttachError`, `ToolchainRebuildError`, `FleetAccessError` and the ad-hoc `NSError(domain:"kinhin")` into the domain enums.
  - Add `GitLabError`/`UpdateCheckError` to CLAUDE.md's list.
- Remove `public` from members of internal types.
- **File renames and moves:**
  - `MainWindowController.swift` → `MainTabsWindowController.swift`
  - Move `DiagnosticsModel`, `LogsModel` and `ForgeCard` into their own files.
  - Rename `Connect/AccountsSection.swift` to `MoreAccountsCard`.
  - Move `GitHubClientFactory` out of `FleetStatus.swift`.
- **MARK style:** `// MARK:` → `// MARK: -` (about 315 sites), in its own commit.

## Phase 6: Tests, docs, CI
- **Tests**
  - Split multi-class test files: `ImagePreparerTests`, `GiteaOnlyTests` (move its CLI class to CLI tests), `BaseImageConfigTests`, `RunnerBootstrapTests`, and the grab-bags `StoreAndLogTests` and `ErrorHandlingTests`.
  - Move misfiled tests to their mirror folders.
  - Add an argv-matching mode to `FakeShell` and fail/block hooks to `FakeTart`, then delete the private `ScriptedShell` ×2 and `BlockingTart`/`FailingBoot`.
  - Extract the duplicated `AuthCommandTests` helpers.
  - Split `KinhinTestSupport/Fakes.swift` into one file per type.
  - Stop using the real login Keychain in `TokenReplacementTests` and `ForgejoTokenMigrationTests`. Drop the Forgejo migration entirely if it's pre-launch dead weight.
- **Docs**
  - Rewrite the stale rows in `docs/architecture.md`: Core/Fleet/Forges/Setup contents, a `ViewModels/` folder that doesn't exist, missing Cache/Intents/GitLab/SwiftUI folders, and the test count, which is ~1290, not 760. Update the count in CLAUDE.md too.
  - `docs/forges.md`, `website/guide/forges.md`, `README.md:86`, `website/guide/quick-start.md:44` and `scripts/install.sh:167` still teach the `gitea:`/`forgejo:`/`repo:` keys, which the parser now rejects. Rewrite them for `accounts:`, and add those patterns to `scripts/docs-lint.sh`.
  - Mark `docs/runtime-abstraction-design.md` as shipped/historical (done). The retired design page was dropped along with its README row.
- **Build/CI**
  - Fix the deployment-target mismatch: `build-app.sh` uses 14.0 but the package says 15.
  - In `ci.yml`, add `swift build -c release --product kinhin-app --product kinhin`, a nightly/`workflow_dispatch` TSan job, and `concurrency: cancel-in-progress`.
  - `release.yml` should run `swift test` and assert the version stamp.
  - `docs.yml` should use `npm ci`.
  - Fix `tsan.sh`, which passes a literal `--` through.

---

## Critical files
`Sources/KinhinKit/Fleet/{FleetEngine,FleetEngine+Credentials,FleetEngine+Reload,FleetLifecycle,FleetReconcile,Daemon,RPCServer,RPCClient}.swift`, `Sources/KinhinKit/Config/{GeneralConfigEditor,BudgetEditor}.swift`, `Sources/KinhinKit/Runtimes/{Runtime,DockerRuntime,AppleContainerRuntime,RuntimesPaneViewModel}.swift`, `Sources/KinhinKit/Forges/*Client.swift`, `Sources/kinhin-app/AppDelegate/*`, `Sources/kinhin-app/UI/SwiftUI/{Connect,MacTools,Toolchains}/*`, `Sources/kinhin/Commands/{Shared,AuthCommand,DoctorCommand}.swift`.

Existing things to reuse: `bestEffortAsync` (`Core/BestEffort.swift`), `withTransientRetry` (`Forges/TransientRetry.swift`), `replaceSectionToggle` (`GeneralConfigEditor+Sections`, which already acts as the edit core), `DoctorReportBuilder`, `KinhinConfig.primaryGitHub`/`forgeView`, and the `KinhinTestSupport` fakes.

## Verification
- After each commit: `swift build`, `swift test`, `swift format lint --strict -r Sources Tests`.
- Phases 1–4 touch actors, Mutexes and RPC, so also run `scripts/tsan.sh` and read its summary. Zero sanitizer reports is required.
- Each Phase 1 bug gets a failing test first:
  - a primary account named `work` + `replaceCredentials`
  - lifecycle deletion still deregisters runners (via `FakeGitHub`/Gitea fake calls)
  - two concurrent `reload_config` calls leave exactly one engine
  - clearing `base_image` with a `container: base_image:` above it
  - `auth status --forgejo` checks the Forgejo account
- Phase 2: a test with a fake daemon socket that never replies must show the app's `refresh` doesn't block the MainActor, and a server test where an idle client doesn't hold the handler.
- Build a release: `swift build -c release --product kinhin-app`. Then run the app (`/run`) to smoke-test Connect, Toolchains, the Fleet start/stop, and a Shortcut against a stopped daemon.
