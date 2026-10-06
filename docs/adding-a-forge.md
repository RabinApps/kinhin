# Adding a new forge to kinhin

A step-by-step checklist for adding support for a new CI forge. It is written for AI agents and for humans. Bitbucket
was the last forge added, so it is the worked example throughout. Buildkite and Azure DevOps followed the same shape.

Read [CONTRIBUTING.md](../CONTRIBUTING.md) first for the build, test, style and error-handling rules, and
[Forge API notes](forges/README.md) for how the existing forges behave.

## How to use this checklist

1. Make the [design decisions](#1-decide-first) before writing code. They drive every later step.
2. Add the `ForgeID` case first. Every `switch` over `ForgeID` is exhaustive with no `default`, so `swift build` then
   lists most of the sites you must touch.
3. Work through sections A to H. Sections marked **manual** contain sites the compiler cannot find.
4. Finish with the [completeness check](#completeness-check) and the [verification](#verification) commands.

Keep each stage in its own commit (see [Commit plan](#commit-plan)). `swift build` and `swift test` must pass on every
commit. Do not commit or push unless asked.

## 1. Decide first

| Decision                                | Options                                                                                                                                                                                                       | Why it matters                                                                                                              |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Registration mode (`ForgeRegistration`) | `.sharedShortLived` (one token for all runners, about 1 h: GitHub), `.sharedLongLived` (Gitea family), `.perRunner` (the forge creates one runner per name, each with its own credentials: GitLab, Bitbucket) | Per-runner forges override `registrationTokens(runnerNames:labels:)`. The result is stored as an opaque string per runner.  |
| Exit semantics (`ForgeExitSemantics`)   | `.deregisters` (the runner deregisters after one job: GitHub, GitLab, Buildkite, Azure DevOps), `.idleGrace` (busy, then idle for 30 s means done: Gitea family, Bitbucket)                                   | Idle-grace forges need `ForgeRunner.online` to be accurate. See `FleetLifecycle.swift`.                                     |
| Hosted or self-hosted                   | Hosted only (Buildkite, Bitbucket) or self-hostable (GitHub Enterprise, Gitea, GitLab, Azure DevOps Server)                                                                                                   | Decides whether `instance` is required, whether `allow_insecure_http` applies, and the `selfHosted` list in config parsing. |
| Scope grammar                           | `owner/name`, `org/cluster`, a pool name, `workspace[/repo]`                                                                                                                                                  | You need a scope validator, plus `attributesByRepo` and `isSingleRepositoryScope` behaviour.                                |
| Runner agent                            | Where it is downloaded, how it is pinned and verified, extra dependencies (Bitbucket needs a JDK), architecture tokens                                                                                        | Drives the install scripts and `RunnerVersions`.                                                                            |
| Demand source                           | kinhin polls. There are no webhooks. Some forges need demand derived indirectly (Bitbucket has no queued-steps endpoint, so it reads active pipelines)                                                        | Drives `queuedJobs()` and `runningJobs()`, and the rate-limit budget.                                                       |

## 2. Checklist

### A. Forge layer (`Sources/KinhinKit/Forges/`)

1. **`Forge.swift`**
   - Add `case <id>` to `ForgeID` with a doc comment, and the `displayName` arm.
   - The raw value is load-bearing. It is the Keychain account (`<raw>-pat[:name]`), the `--<raw>` CLI flag, the `forge:`
     value in `config.yaml` and the icon filename. Never rename it later.
   - Case order is the display order in the app pickers, CLI help and config errors.
2. **`<Name>Models.swift`**
   - `<Name>Credentials` (token, scope, optional instance, `allowInsecureHTTP`) with `static func isValidScope(_:)`.
     Self-hosted forges also get `validate(instance:allowInsecureHTTP:)`.
   - `Decodable` wire models, and a scope type if scopes have structure (`BitbucketScope`).
   - `<Name>Error: LocalizedError` with actionable text that names the fix (for example `kinhin auth set ...`), carrying
     only what is forge-specific: a malformed instance URL, missing scopes, an unknown pool. The HTTP-shaped failures
     (401, 403, 404, other statuses, decoding) come from the shared transport as `ForgeAPIError`, whose per-forge
     remediation text lives in one table there — extend that table, not a new enum.
3. **`<Name>Client.swift`**: `struct <Name>Client: Sendable`.
   - Build the session with `ForgeHTTP.session(session)`, which carries the redirect and insecure-http guards. For
     self-hosted forges also use `ForgeHTTP.permitsScheme(of:allowInsecureHTTP:)`.
   - Hold one `ForgeTransport` (session, your `ForgeID`, the forge's `Authorization` scheme) and send every request
     through it: it applies the auth header, retries transient failures (network errors, 429, 5xx) with backoff, and
     maps 401, 403, 404 and other statuses to `ForgeAPIError`. The client keeps URL construction, pagination and
     decoding. A forge-specific response quirk rides the transport's `classify` hook (see Azure's sign-in pages).
   - Validate pagination `next` links against the API host by comparing parsed hosts, not string prefixes
     (`BitbucketClient.isTrustedPageLink`). Never send the token to another host.
   - Methods: verify scope or token, list, create and delete runners, list queued and running jobs, and
     `listScopes()` or `listRepositories()` for the app's picker.
4. **`<Name>Forge.swift`**: `struct <Name>Forge: Forge`. Implement every protocol member:

   | Member                                                             | Notes                                                                                                                                                         |
   | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
   | `id`, `name`, `account`, `credentials`, `labels`                   | `account` defaults to `id.rawValue`. The engine passes `account.name`.                                                                                        |
   | `registration`, `exitSemantics`                                    | From the decisions above.                                                                                                                                     |
   | `attributesByRepo`                                                 | Default is "scope has no slash". Override if that is wrong for your grammar.                                                                                  |
   | `registrationURL()`                                                |                                                                                                                                                               |
   | `mintRegistrationToken()`                                          | Per-runner forges throw `EngineError.registrationFailed`.                                                                                                     |
   | `registrationTokens(runnerNames:labels:)`                          | Default mints one shared token. Per-runner forges create the runners here, and call `runnerList.invalidate()`. Secrets shown only once must be captured here. |
   | `runners()`                                                        | Report `online:` honestly.                                                                                                                                    |
   | `deleteRunner(id:)`                                                | `ForgeRunner.id` is a string.                                                                                                                                 |
   | `queuedJobs()`, `runningJobs()`                                    | Fill `repository`, `labels`, `ref`, `sha`, `isFork` when the API exposes them. `ref` and `sha` are required for per-project toolchains.                       |
   | `rateLimit`                                                        | Optional, defaults to nil.                                                                                                                                    |
   | `projectFile(repository:ref:)`                                     | Optional. Only GitHub, Gitea/Forgejo and GitLab implement it, so other forges fall back to `projects[].toolchains`.                                           |
   | `pipelineDetail(runnerName:repository:)`, `pipelineLog(job:step:)` | Optional. Use `PipelineLogText.clean`.                                                                                                                        |
   - Add `static func make(credentials:labels:account:session:) async throws`, which builds the client and verifies the
     scope and token so a bad token fails fast.
   - Cache runner and job lists with `SharedListCache` (3 s TTL). The exit watch polls every second.

5. **`TokenRequirements.swift`**: add `static func <id>(scope:)`. It is shown in the app and CLI as "token permissions".
6. **`TokenHealthCheck.swift`**: add `public static func <id>(token:scope:...) async -> Report`, then fill in the
   exhaustive switches: `check(forge:config:keychainToken:...)`, `account(_:token:)` and
   `repositories(forge:token:instance:allowInsecureHTTP:)`.
7. **`Core/ErrorCategory.swift`**: add `is <Name>Error` to the `.auth` case list (`ForgeAPIError` is already there).

### B. Config (`Sources/KinhinKit/Config/`)

8. **`AccountConfig.swift`**: add arms to `isValidScope(_:forge:)` and `isSingleRepositoryScope`. Do not add the forge
   to `reservedNames`. That set is only `github`, `gitea` and `forgejo`.
9. **`ConfigLoader+Sections.swift`, `parseAccounts`**
   - The scope-error `switch`.
   - **Manual:** the `selfHosted` array literal is not exhaustive. Add the forge only if it supports
     `allow_insecure_http`, and update that error message's list.
   - The per-forge `switch forge`: validate `instance` (required or forbidden) and `labels` (non-empty, reserved names,
     format), then build `AccountConfig`.
   - The "unknown forge" message is derived from `ForgeID.allCases`.
10. `ConfigDTO`, `ConfigModel`, `ConfigLoader` and `AccountsConfigEditor` need no change. `ConfigTemplate.swift` has
    only commented GitHub, Gitea and GitLab examples. Adding a commented example is optional.

### C. Engine

11. **`Fleet/FleetEngine+Accounts.swift`, `attach(account:token:verify:)`**: add the arm calling `<Name>Forge.make(...)`.
    Pass `account.allowInsecureHTTP ?? false` for self-hosted forges.
12. **`Core/LogRedactor.swift`** (**manual**): add a pattern for the forge's token prefix, and a case in
    `LogRedactorTests`. Register per-runner secrets with `LogRedactor.registerSecret` when they are created.
13. `FleetLifecycle`, `ForgeDemand`, `FleetReconcile`, the Keychain store and the RPC token swap are generic. Touch them
    only when adding a new `ForgeRegistration` or `ForgeExitSemantics` case.

### D. Runner bootstrap

The runner has to be installed (in the base image, or on the host) and started for each runtime.

14. **Registration scripts**: one per runtime. The compiler finds these switches on `forge.credentials.forge`:
    - `Runtimes/Runtime.swift`, `TartRuntime.registrationScript` (guest may be macOS or Linux, so paths use `$HOME/...`).
    - `Runtimes/LinuxContainerCLI.swift` (Apple container and Docker, `/opt/<agent>` layout).
    - `Runtimes/HostRuntime.swift` plus a new `Runtimes/HostRuntime+<Name>.swift`, including a `stop<Name>...` method
      called from teardown (compare `stopGitLabRunners`) so host runners die with the instance.
15. **`Images/RunnerBootstrap/RunnerBootstrap+<Name>.swift`**
    - Registration script: write credentials to a `umask 077` private file read inside the background job, delete it
      after the agent reads it, and never export secrets into the job environment or put them in `ps`.
    - Install scripts for macOS, the Linux container, and `RunnerBootstrap+TartLinux.swift`
      (`tartLinux<Name>InstallScript`). Use `verifiedDownloadScript(url:file:expectedDigestCommand:)` from
      `RunnerBootstrap+Verification.swift`, and pin by digest or vendor checksum.
    - If runner names map to credentials, follow `bitbucketRunners(name:runnerCount:tokens:)` and
      `FleetEngine.runnerNames(for:count:)`.
16. **`Images/RunnerVersions.swift`**: add the version fields and init parameter defaults, `pinned<Name>` constants (with
    a digest map if the vendor publishes none), a `fallback` entry, and optionally a `latest<Name>()` feed. Add any
    architecture token to `Images/LinuxPlatform.swift`.
17. **Baking and installing** (**manual**: none of these are exhaustive switches, and each is easy to forget):
    - `Images/ImagePreparer.swift`: add `has<Name>Token` to `Options` and its init, the `AccountTokens.anyStored(for:)`
      probe, the no-credentials guard, and an install block per `guestOS`.
    - `Images/LinuxImageBaker.swift`: the same, in `LinuxImageOptions`.
    - `Setup/HostAgentInstaller.swift`: an `include<Name>` flag, extend the `configured == nil` guard, add
      `<name>Installed` to `isInstalled`, an install block, an `installedSummary` line, and a post-install check.

### E. CLI (`Sources/kinhin/Commands/`)

18. **`AuthCommand.swift`**
    - `AuthEnvironment`: add `check<Name>`, defaulting to `TokenHealthCheck.<id>`.
    - Exhaustive switches: `requirements(for:config:)`, the expected-scope message in `add`, the token-kind label, and
      the per-forge arm in `auth status`.
    - Flags (`--<raw>`), `forgeFlagList` and `resolveTarget` derive from `ForgeID.allCases`.
19. **`HelpText.swift`** (**manual**): the product blurb, the `auth add NAME --a|--b|...` line, and the per-forge agent
    list in the `image prepare` or setup section.

### F. App (`Sources/kinhin-app/`)

20. **`UI/SwiftUI/Connect/ForgeConnectionModel.swift`**: `instancePlaceholder`, the scope label and placeholder,
    `requirements`, `verifyAfterConnect`, and the booleans that decide instance requirements (`showsInstance`,
    `countsAsConnected`, `listRepos`). The booleans are **manual**.
21. **`ForgeConnectionModel+Config.swift`**: add the forge to the case list that writes the `AccountConfig`.
22. **`UI/SwiftUI/Connect/AccountsModel.swift`**: scope placeholder, `instancePlaceholder`, `requirements`, and the
    instance-required boolean.
23. **Icon**: add `Resources/ForgeIcons/<rawValue>.svg`. Use the Simple Icons CC0 single-colour mark unmodified, and
    record the version in `Resources/ForgeIcons/README.md`. `ForgeIconTests` fails for any `ForgeID` without an icon.
    Wiring (`Package.swift` resources, `scripts/build-app.sh`) is already generic.
24. The wizard and Connect screens iterate `ForgeID.allCases`. No per-forge code, except
    `WizardModelTests`, which hardcodes the joined name string (see G).

### G. Tests (all three test targets)

25. `Tests/KinhinKitTests/Forges/`
    - `<Name>ClientTests`: against `StubProtocol`. Cover the auth header, list, create and delete runner, 404 on delete,
      scope verify, demand, pagination, `ForgeTransport.isTransient`, and `ErrorCategory`.
    - `<Name>ForgeTests`: the `Forge` surface and credential-bundle capture.
    - `<Name>PipelineDetailTests`, and a `<Name>` case in `PipelineLogFetchTests`.
    - `ForgeTransportTests` for untrusted page-link hosts, and `TokenRequirementsTests`.
26. `Tests/KinhinKitTests/Images/<Name>RegistrationScriptTests`: paths per runtime, the private credential file, start
    flags, install-script digest and platform segments. Extend `ImagePreparerTests` and `TartLinuxBakeScriptTests`.
    Pass `has<Name>Token: false` alongside the other forges' overrides in `ForgeTests`, `ImagePreparerTests` and
    `LinuxImageBakerTests`, so no test probes the real Keychain.
27. `Tests/KinhinKitTests/Config/`: a `<Name>AccountConfigTests` file, `InsecureHTTPAccountConfigTests` (hosted forges
    reject `allow_insecure_http`), and `HostScopeValidationTests` if relevant.
28. `Tests/KinhinKitTests/Setup/HostAgentInstallerTests`: add `<name>:` to the `installer(...)` helper, with tests for
    the install script, `isInstalled` and the summary.
29. `Tests/KinhinKitTests/Core/LogRedactorTests`, and `RunnerVersionResolverTests` if you added a feed.
30. CLI: `ConfigInitAndHelpTests` (flag list and help blurb), `AuthTestSupport` (add `checked<Name>` to the recorder and
    wire `env.check<Name>`), and a round-trip test in `AuthAccountsCommandTests`.
31. App: `WizardModelTests` (the forge name string), and `ForgeIconTests` (automatic once the SVG exists).
32. `KinhinTestSupport` has fakes only for engine-level doubles (`FakeGitHub`, `FakeGitea`, `FakeGitLab`). Add a
    `Fake<Name>` only if engine-level tests need one, and pin any new fake with a `<Fake>ContractTests` file in
    `Tests/KinhinKitTests/TestSupport/` against the real client over `StubProtocol` (see the shared-doubles rules in
    `CONTRIBUTING.md`). Buildkite, Azure DevOps and Bitbucket use `StubProtocol` stubs.
    New test globals use a `Mutex`, not `nonisolated(unsafe)`.

### H. Docs and website

33. `docs/forges/<id>.md`: the API notes page. Copy the structure of `docs/forges/bitbucket.md` (overview, auth,
    endpoints, registration flow, demand and label matching, pagination, audit findings, "Verified" date).
34. `docs/forges/README.md`: add a row to each table and update the audit summary.
35. `docs/forges.md`: the top table, the "What has been tested" table (a new forge is "untested"), a `### <Name>` setup
    section with a YAML example, and the plain-http and per-project-toolchain paragraphs if they apply.
36. `website/.vitepress/config.ts`: add the page to the "Forge API notes" sidebar group. `docsLinks.ts` needs no change.
37. **Manual:** every other place that lists forges. Compare with `git show 9a0f846 --stat`: `README.md` (about 8 spots),
    `docs/architecture.md`, `docs/app.md`, `docs/why.md`, `docs/beta-roadmap.md`, `docs/toolchains.md`,
    `docs/runtimes.md` (label selection), `docs/security.md` (registration token exposure),
    `docs/plans/per-project-toolchains.md`, `website/index.md`, `website/guide/quick-start.md`,
    `website/cli/commands.md`, `.github/ISSUE_TEMPLATE/bug_report.md`, `CHANGELOG.md`, and the error-enum list in
    `CONTRIBUTING.md`.
38. `scripts/docs-lint.sh` is a stale-string table, not a forge check. Add rows only if you rename something.

## What the compiler finds, and what it does not

| `swift build` finds                                                                | Find these yourself (**manual**)                                                                       |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `ForgeID.displayName`, `AccountConfig.isValidScope` and `isSingleRepositoryScope`  | The `selfHosted` array in `parseAccounts`                                                              |
| `parseAccounts` switches, `FleetEngine.attach`                                     | `AccountTokens.anyStored` probes and the no-credentials guard in `ImagePreparer` and `LinuxImageBaker` |
| `TokenHealthCheck` switches                                                        | `HostAgentInstaller` flags, install block and summary                                                  |
| `AuthCommand` switches                                                             | `LogRedactor` patterns                                                                                 |
| `registrationScript` in Tart, container and host runtimes                          | `HelpText` strings                                                                                     |
| `ForgeConnectionModel`, `ForgeConnectionModel+Config` and `AccountsModel` switches | `ForgeConnectionModel` and `AccountsModel` booleans                                                    |
|                                                                                    | `WizardModelTests` hardcoded string, test-helper overrides (`has<Name>Token: false`)                   |
|                                                                                    | Icon (caught by `ForgeIconTests`), all docs mentions and the website sidebar                           |

## Gotchas

- **Per-runner secrets are shown once.** Capture them in `registrationTokens`, throw a dedicated error if absent, and
  invalidate the runner cache after creating runners.
- **Idle-grace forges.** The engine only sees "busy, then idle", so `ForgeRunner.online` must stay false until the agent
  has connected, or the exit watch fires early.
- **Rate limits.** Poll within the forge's budget. Bitbucket reads at most 20 recently active repositories, one page
  each, to stay near 1000 requests per hour. Share lists through `SharedListCache`.
- **Transport security.** HTTPS only, except `allow_insecure_http` on self-hosted forges (loopback is exempt). Validate
  the host of every pagination URL before sending the token.
- **Secrets in jobs.** Never export registration credentials into the job environment. Use a `umask 077` file that the
  agent reads once and that is then deleted.
- **Per-project toolchains** need `ForgeJob.ref`, `ForgeJob.sha` and `projectFile`. Without them jobs use only
  `projects[].toolchains` or the base image.
- **Label routing.** Check `docs/runtimes.md` for which forges honor `runs-on` label selection. A forge that registers
  with the fleet labels only cannot route by label.
- **Status honesty.** Document a new forge as untested until it has run for real (see `docs/beta-roadmap.md`).
- **Dirty trees.** Check `git status` first. Do not mix unrelated changes into the forge commits.

## Completeness check

Compare against the previous forge. Every file that mentions it should have a counterpart for the new one:

```bash
rg -il bitbucket Sources Tests docs website README.md CHANGELOG.md CONTRIBUTING.md .github scripts
rg -il <newforge> Sources Tests docs website README.md CHANGELOG.md CONTRIBUTING.md .github scripts
```

Diff the two lists. A file in the first list but not the second is either a forge-specific file you still need to
write, or a place where the new forge is missing from a list.

## Verification

Run from the repository root:

```bash
swift build
swift format format -i -r Sources Tests   # mechanical, commit separately
swift format lint --strict -r Sources Tests
swift test                                # about 2 minutes, no VMs or network
swift test --filter <Name>                # fast loop while developing
swift build -c release --product kinhin-app --product kinhin
scripts/tsan.sh                           # if you added shared state, a Mutex box or a test global
bash scripts/docs-lint.sh
cd website && npx vitepress build         # fails on dead links
```

Then smoke-test the CLI and app:

```bash
.build/debug/kinhin auth add test --<id> --scope <scope> && .build/debug/kinhin config validate
.build/debug/kinhin --help | grep -- --<id>
scripts/dev-run.sh    # check the Connect chip, the icon and the token check
```

## Commit plan

Mirror the Bitbucket sequence. Each commit builds and passes tests.

| Stage          | Bitbucket commit     | Contents                                                                                                                   |
| -------------- | -------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| 1. Client      | `acd8750`            | REST client, models, error enum, client tests, `ErrorCategory`                                                             |
| 2. Wiring      | `e8ca1b5`            | `ForgeID` case, forge adapter, config, engine attach, per-runtime bootstrap, token health and requirements, CLI, app forms |
| 3. Runner bake | `ea92828`            | Image preparers, `RunnerVersions`, `HostAgentInstaller`                                                                    |
| 4. Tests       | `595501c`            | Forge, registration-script, install-script and Linux-image tests                                                           |
| 5. Docs        | `9a0f846`, `1920cfe` | Mentions, `docs/forges/<id>.md`, sidebar                                                                                   |
| 6. Icon        | `6cda21e`            | `ForgeIcons/<id>.svg`                                                                                                      |

Later fixes on Bitbucket (`ebc00aa` insecure-http opt-in, `eb19cb3` redaction and secret handling) are the sites most
often missed the first time. Check them in this document's sections A to D before you call a forge done.
