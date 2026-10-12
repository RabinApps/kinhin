# Mobile fastlane: test checklist

Everything that must be tested before the fastlane integration (`kinhin mobile init`, `templates/mobile/`,
`examples/`) merges. Status values:

- **Done**: verified and covered by an automated check.
- **Automated**: covered by the `MobileScaffoldTests` Swift tests or `scripts/mobile-e2e.sh`.
- **Local**: needs tools on this Mac, but no credentials. Run by `scripts/mobile-e2e.sh`.
- **Creds**: needs real store or CI credentials. Cannot run without the owner.
- **Open**: not done yet.

## 1. Scaffolding (`kinhin mobile init`)

| # | Check | Status | How |
| --- | --- | --- | --- |
| 1.1 | Unknown framework and missing directory fail with a usage error | Done | `MobileScaffoldTests` and the CLI `--framework` check |
| 1.2 | Empty directory fails with a pass `--framework` hint | Done | `MobileScaffoldTests` |
| 1.3 | Flutter, React Native, Expo, root iOS, root Android detection | Done | `MobileScaffoldTests` |
| 1.4 | Explicit `--framework` wins over folders | Done | `MobileScaffoldTests` |
| 1.5 | Existing Gemfile without fastlane gets fastlane appended once | Done | `MobileScaffoldTests` |
| 1.6 | Re-run keeps edited files; `--force` overwrites | Done | `MobileScaffoldTests` |
| 1.7 | `--dry-run` writes nothing | Done | `MobileScaffoldTests` |
| 1.8 | Missing template fails before any write | **Done** | `MobileScaffoldTests` (kit copy with one template removed) |
| 1.9 | Passes under macOS `/bin/bash` 3.2 | Superseded | The bash scaffold was removed. The logic is Swift now, so the bash 3.2 check no longer applies. |
| 1.10 | Passes on Ubuntu (the CI docs job) | Superseded | The bash scaffold was removed. The Swift tests run in the CI test job on macOS. |
| 1.11 | Monorepo: app in a subdirectory, `dir` argument | **Done** | Fixture: `apps/mobile/` with a root Gemfile in the subdir |
| 1.12 | Expo project with prebuilt `ios/` and `android/` folders | **Done** | Expo `prebuild` fixture; expect `eas.json` only |
| 1.13 | `react-native` only in `devDependencies` still detected | **Done** | Fixture with the key under `devDependencies` |
| 1.14 | Ruby 2.6 system Gemfile: `ruby` directive is not duplicated | **Done** | Gemfile with `ruby` line plus appended fastlane |

## 2. Generated CI workflow

| # | Check | Status | How |
| --- | --- | --- | --- |
| 2.1 | Generated YAML parses and has only the expected jobs | Done | `MobileScaffoldTests` (YAML + job presence) |
| 2.2 | Each job runs `ruby/setup-ruby` with Ruby 3.3 | Done | `MobileScaffoldTests` (Flutter case) |
| 2.3 | Workflow `working-directory` matches the scaffolded folder | Done | `MobileScaffoldTests` |
| 2.4 | `actionlint` clean on the generated workflows | **Done** | Install `actionlint`, run on each example workflow |
| 2.5 | Runs on a kinhin runner with the `kinhin-xcode` label | Creds | Trigger `workflow_dispatch` on a fleet |
| 2.6 | `ruby/setup-ruby` works on the self-hosted macOS arm64 runner | Creds | Same run as 2.5 |
| 2.7 | Secrets written to `$RUNNER_TEMP` are removed when the job fails | Creds | Force a failing lane; check the temp path is gone |
| 2.8 | `actions/checkout` and `setup-java` pins match `ci.yml` policy | **Done** | Decide: pin to SHAs like `ci.yml`, or keep tags and say so |

## 3. Lanes (templates)

| # | Check | Status | How |
| --- | --- | --- | --- |
| 3.1 | Every example lists its lanes (`fastlane lanes`) | Done | Ran in each example folder |
| 3.2 | iOS `beta` with no secrets stops before any store call | Done | `fastlane ios beta` in `ios_native_app` |
| 3.3 | Android `beta` with no secrets stops before any store call | Done | `fastlane android beta` in `android_native_app` |
| 3.4 | Missing `ASC_KEY_FILEPATH` on disk gives a clear error | **Done** | Set a path that does not exist; expect the `does not exist` message |
| 3.5 | Missing keystore gives a clear error | **Done** | Unset `AAB_PATH`, point the keystore at a missing file |
| 3.6 | `AAB_PATH` pointing at no file gives a clear error | **Done** | Set `AAB_PATH=/nope.aab` with a fake Play JSON |
| 3.7 | Option names exist in fastlane 2.241 | **Done** | `fastlane action <name>` for every action and option used |
| 3.8 | `match` readonly and `app_store_connect_api_key` produce a usable key | Creds | Real App Store Connect key and match repo |
| 3.9 | `build_app` produces an IPA for an App Store export | Creds | Signed build with a distribution profile |
| 3.10 | `upload_to_testflight` uploads a build | Creds | Test app in App Store Connect |
| 3.11 | `upload_to_app_store` skips metadata and screenshots | Creds | Test app with a processed build |
| 3.12 | `upload_to_play_store` uploads to the internal track | Creds | Play service account with release rights |
| 3.13 | `gradle` signs the AAB from the injected properties | **Done** | Build with a throwaway keystore; check the signature |
| 3.14 | `setup_ci` works on a macOS CI runner | Creds | Runner run in 2.5 |

## 4. Example apps

| # | Check | Status | How |
| --- | --- | --- | --- |
| 4.1 | `ios_native_app` builds for the simulator (signing off) | Done | `xcodebuild` |
| 4.2 | `android_native_app` builds a debug APK on Java 17 | Done | `./gradlew assembleDebug` |
| 4.3 | `android_native_app` builds a release AAB | **Done** | `./gradlew bundle` with a throwaway keystore |
| 4.4 | `flutter_app` builds an AAB unsigned | **Done** | `flutter build appbundle` |
| 4.5 | `flutter_app` builds a signed IPA | Creds | Needs a distribution certificate |
| 4.6 | `RnApp` installs pods | **Done** | `pod install` in `ios/` |
| 4.7 | `RnApp` builds for the simulator | **Done** | `xcodebuild` after `pod install` |
| 4.8 | `RnApp` builds an AAB | **Done** | `./gradlew bundle` in `android/` |
| 4.9 | `expo_app` `eas.json` validates | Creds | `npx eas-cli` validate (may need network) |
| 4.10 | Examples are tracked from a clean clone | Done | Checked `git ls-files` for key files |

## 5. Docs, skill and repo gates

| # | Check | Status | How |
| --- | --- | --- | --- |
| 5.1 | `scripts/check.sh` passes, including the Swift test run | Done | Full run; one flaky `ToolchainHelperScriptTests` run, then pass |
| 5.2 | `skills-lint.sh` clean | Done | `check.sh` |
| 5.3 | `docs-lint.sh` and `docs-sync.sh --check` clean | Done | `check.sh` |
| 5.4 | `changelog.sh check` clean | Done | `check.sh` |
| 5.5 | VitePress build passes (no dead links) | Done | `npx vitepress build` |
| 5.6 | In-page anchors (`#secrets`) resolve | **Done** | Check the rendered page for the `secrets` id |
| 5.7 | `docs/mobile-fastlane.md` matches the script's behaviour | **Done** | Read against the script and fixtures |
| 5.8 | Flaky `ToolchainHelperScriptTests` under `--parallel` | **Done** | Root cause: `Shell` read a pipe's final chunk after the snapshot, so short stderr could be lost. Fixed in `Core/Shell.swift` (wait for EOF on both pipes). Regression test `ShellTests.testShellNeverLosesShortStderrUnderConcurrency`: fails 3–4 of 4000 runs on the old code, 0 on the fix. Full `check.sh` and `tsan.sh` pass. |

## 6. Repo hygiene

| # | Check | Status | How |
| --- | --- | --- | --- |
| 6.1 | No build output or vendored gems are tracked | Done | `git diff --cached` checks |
| 6.2 | Branch rebased onto current `origin/develop` | **Done** | Rebased onto `origin/develop` (1704779) |
| 6.3 | Full `check.sh` after the rebase | **Done** | Full run passed after the rebase (exit 0) |

## 7. End-to-end

| # | Check | Status | How |
| --- | --- | --- | --- |
| 7.1 | `scripts/mobile-e2e.sh` scaffolds every example and runs lanes | **Done** | Script; see below |
| 7.2 | Validation errors fire for each lane with no secrets | **Done** | Script |
| 7.3 | Local builds run where tools exist, skip with a reason where not | **Done** | Script |
| 7.4 | Store and CI steps stay manual | Creds | Documented as manual; `.github/workflows/mobile-e2e.yml` is `workflow_dispatch` only and uses no secrets |

## 8. kinhin CLI and framework CI steps

| # | Check | Status | How |
| --- | --- | --- | --- |
| 8.1 | `kinhin mobile init` output matches the committed examples byte for byte | **Done** | `scripts/mobile-e2e.sh` drift stage (uses the built binary) |
| 8.2 | Detection, scaffolding, Gemfile append, keep, force, dry run, Expo, monorepo, error paths | **Done** | `MobileScaffoldTests` (18 cases, in `swift test`) |
| 8.3 | Embedded templates equal `templates/mobile/` | **Done** | `MobileScaffoldTests.testEmbeddedTemplatesMatchTheTemplateFiles`; regenerate with `scripts/mobile-templates-embed.py` |
| 8.4 | Flutter CI steps: SDK, `pub get`, `build ios --config-only`, before CocoaPods | **Done** | `MobileScaffoldTests` checks the order; e2e mirrors the commands locally |
| 8.5 | React Native CI steps: Node, npm/yarn install, before CocoaPods | **Done** | `MobileScaffoldTests` checks the order; e2e mirrors the commands locally |
| 8.6 | Flutter iOS Release device build, signing off | **Done** | e2e (`flutter_app Release device build`). A Debug simulator build needs an engine that `--config-only` does not produce. |
| 8.7 | Flutter Android lane builds a signed AAB at the Flutter output path | **Done** | e2e `lane_build_signed` (`fastlane android build`, `jarsigner`) |
| 8.8 | React Native Android lane builds a signed AAB | **Done** | e2e `lane_build_signed` |
| 8.9 | Generated Flutter and React Native jobs run on a kinhin runner | Creds | `.github/workflows/mobile-e2e.yml` runs the e2e; a generated job needs a real project |
| 8.10 | `ruby/setup-ruby`, `subosito/flutter-action` and `actions/setup-node` work on the self-hosted arm64 runner | Creds | Same runner run as 8.9 |

## 9. Monorepos, Expo with fastlane, package managers, and docs

| # | Check | Status | How |
| --- | --- | --- | --- |
| 9.1 | Workflow paths are relative to the git repository (monorepo app at `apps/mobile`) | **Done** | `MobileScaffoldTests.testMonorepoAppGetsWorkflowPathsFromTheRepositoryRoot`; the e2e copy is a git repo, so the example paths are checked too |
| 9.2 | A project with no repository above it uses its own root | **Done** | `MobileScaffoldTests.testProjectOutsideAnyRepositoryUsesTheProjectRoot`; a 20-second run on a non-repo folder terminates (the walk stops at `/`) |
| 9.3 | Expo with fastlane: `expo prebuild`, then the React Native template, then the signed Android lane, pods and the Release device build | **Done** | e2e `expo_app` steps (with `--with-builds`) |
| 9.4 | Yarn, pnpm, npm and no-lockfile install steps in the React Native setup | **Done** | e2e `install step with ...`, running the template text for each lockfile kind. Fixed: `corepack enable` needed `/usr/local/bin`, so the shims now go to a job-owned directory. |
| 9.5 | Tutorial, credentials and troubleshooting pages build, and their anchors resolve | **Done** | VitePress build (no dead links); anchors checked in the built HTML |
| 9.6 | Tutorial steps work for a new user with real accounts | Creds | Needs an Apple Developer account and a Play Console account to walk through |
| 9.7 | Flutter Debug simulator build | Known gap | Does not work with Flutter 3.41: `Flutter.framework` has no simulator architectures. Documented in the troubleshooting page. The Release device build passes. |
| 9.8 | A fresh `flutter create` project: init, lanes, signed Android lane, and the iOS Release build after the documented deployment-target fix | **Done** | e2e `fresh flutter ...` steps (with `--with-builds`) |
| 9.9 | `kinhin mobile init` notes an iOS deployment target below 15.0, with the file and the fix, and does not edit the project | **Done** | `MobileScaffoldTests.testLowIOSDeploymentTargetIsNotedWithTheFix` and the current-target case; e2e fresh-project step |
| 9.10 | `kinhin mobile init` exits 2 for an unknown framework, a missing folder, a folder with no project, and a bare `kinhin mobile` | **Done** | e2e "kinhin mobile init reports usage errors" (always runs) |

## 10. Verification against sources, pinning, Ruby, and CLI tests

| # | Check | Status | How |
| --- | --- | --- | --- |
| 10.1 | Every action in a generated workflow is pinned to a commit SHA | **Done** | `MobileScaffoldTests.testEveryGeneratedActionIsPinnedToACommitSHA`; the examples are regenerated |
| 10.2 | Apple and Google claims in the credentials, tutorial and reference pages match the official pages | **Done** | Sources listed at the end of `docs/mobile-credentials.md`. Corrected: team key creation (Account Holder or Admin), the Play test-track permission, the first manual upload, and the upload-key reset. |
| 10.3 | The Ruby minimum is 3.2 | **Done (metadata)** | fastlane 2.241.0 declares `required_ruby_version >= 3.2.0`. The Ruby 3.2 runtime was not run: this Mac only has Ruby 3.3 installed. |
| 10.4 | `kinhin mobile init` argument parsing and exit codes | **Done** | `MobileCommandTests` |
| 10.5 | Apple Team ID location | Open | Not in Apple's help index; checked against the account page only |
| 10.6 | Apple role that can upload builds with a team key | Open | Not stated by Apple's API page |
| 10.7 | Play permission a service account needs for test-track uploads | Open | Google lists the permission but does not say which one a service account needs |
