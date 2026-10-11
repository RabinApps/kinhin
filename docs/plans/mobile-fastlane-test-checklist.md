# Mobile fastlane: test checklist

Everything that must be tested before the fastlane integration (`scripts/mobile-init.sh`, `templates/mobile/`,
`examples/`) merges. Status values:

- **Done**: verified and covered by an automated check.
- **Automated**: covered by `scripts/mobile-init-test.sh` or `scripts/mobile-e2e.sh`, not yet run in CI.
- **Local**: needs tools on this Mac, but no credentials. Run by `scripts/mobile-e2e.sh`.
- **Creds**: needs real store or CI credentials. Cannot run without the owner.
- **Open**: not done yet.

## 1. Scaffolding (`scripts/mobile-init.sh`)

| # | Check | Status | How |
| --- | --- | --- | --- |
| 1.1 | Help, unknown option, unknown framework, missing directory exit 2 | Done | `mobile-init-test.sh` |
| 1.2 | Empty directory fails with a pass `--framework` hint | Done | `mobile-init-test.sh` |
| 1.3 | Flutter, React Native, Expo, root iOS, root Android detection | Done | `mobile-init-test.sh` |
| 1.4 | Explicit `--framework` wins over folders | Done | `mobile-init-test.sh` |
| 1.5 | Existing Gemfile without fastlane gets fastlane appended once | Done | `mobile-init-test.sh` |
| 1.6 | Re-run keeps edited files; `--force` overwrites | Done | `mobile-init-test.sh` |
| 1.7 | `--dry-run` writes nothing | Done | `mobile-init-test.sh` |
| 1.8 | Missing template fails before any write | **Done** | `mobile-init-test.sh` (kit copy with one template removed) |
| 1.9 | Passes under macOS `/bin/bash` 3.2 | Done | Ran `/bin/bash scripts/mobile-init-test.sh` |
| 1.10 | Passes on Ubuntu (the CI docs job) | Done | Ran in `ubuntu:24.04` container |
| 1.11 | Monorepo: app in a subdirectory, `dir` argument | **Done** | Fixture: `apps/mobile/` with a root Gemfile in the subdir |
| 1.12 | Expo project with prebuilt `ios/` and `android/` folders | **Done** | Expo `prebuild` fixture; expect `eas.json` only |
| 1.13 | `react-native` only in `devDependencies` still detected | **Done** | Fixture with the key under `devDependencies` |
| 1.14 | Ruby 2.6 system Gemfile: `ruby` directive is not duplicated | **Done** | Gemfile with `ruby` line plus appended fastlane |

## 2. Generated CI workflow

| # | Check | Status | How |
| --- | --- | --- | --- |
| 2.1 | Generated YAML parses and has only the expected jobs | Done | `mobile-init-test.sh` (YAML + job presence) |
| 2.2 | Each job runs `ruby/setup-ruby` with Ruby 3.3 | Done | `mobile-init-test.sh` (Flutter case) |
| 2.3 | Workflow `working-directory` matches the scaffolded folder | Done | `mobile-init-test.sh` |
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
| 5.8 | Flaky `ToolchainHelperScriptTests` under `--parallel` | Open | Not reproduced in 12 isolated runs. Follow-up task `task_896c9d02` investigates it. Not caused by this change: the Swift code matches `origin/develop`. |

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
