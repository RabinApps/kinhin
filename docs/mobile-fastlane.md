# Mobile releases with fastlane

Scaffold fastlane into an iOS, Android, Flutter, React Native or Expo project, and run store uploads from a kinhin
runner. One script writes the lanes, a pinned Gemfile and a manual release workflow. Nothing is uploaded until you
trigger the workflow.

[← Back to toolchains](toolchains.md)

## Quick start

From a kinhin checkout, point the script at your project:

```bash
scripts/mobile-init.sh /path/to/your/app
```

It detects the framework, then writes only the files that are missing:

| Project | Detected by | Writes |
| --- | --- | --- |
| Flutter | `pubspec.yaml` | `Gemfile`, `ios/fastlane/`, `android/fastlane/`, `.github/workflows/mobile-release.yml` |
| React Native (bare) | `"react-native"` in `package.json` | same as Flutter |
| Expo | `"expo"` in `package.json` | `eas.json` only. Expo uses EAS by default (see [Expo](#expo)). |
| Native iOS | `ios/` or `*.xcodeproj` / `*.xcworkspace` | `Gemfile`, `fastlane/` (or `ios/fastlane/`), workflow |
| Native Android | `android/` or `settings.gradle(.kts)` | `Gemfile`, `fastlane/` (or `android/fastlane/`), workflow |

Flags:

- `--framework ios|android|flutter|react-native|expo|native` overrides detection.
- `--force` overwrites files that already exist.
- `--dry-run` prints what would be written.

Then, in the project:

```bash
bundle install
# Run from the folder that holds fastlane/: ios/ or android/ for Flutter and React Native,
# the project root for a native project with its project file at the root.
cd ios && bundle exec fastlane lanes
cd ../android && bundle exec fastlane lanes
```

## Lanes

| Platform | Lane | What it does |
| --- | --- | --- |
| iOS | `beta` | `match` (readonly) → `build_app` (App Store export) → `upload_to_testflight` |
| iOS | `release` | `upload_to_app_store` with metadata and screenshots skipped; not submitted for review |
| Android | `beta` | `gradle` builds a release AAB (or uses `AAB_PATH` if another step built it) → `upload_to_play_store` to the internal track |

The templates use the documented fastlane interfaces: `app_store_connect_api_key` with `match`, `pilot` and `deliver`
with API key auth, and `supply` with a service account JSON. See the sources at the end.

## Secrets

Nothing secret is committed. Create these as repository secrets, and the workflow maps them into the lanes:

| Secret | Used for |
| --- | --- |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API key. The `.p8` file is written to a temp path in the job, then deleted. |
| `MATCH_GIT_URL`, `MATCH_PASSWORD` | Encrypted certificates repo for `match` (readonly on CI) |
| `APPLE_TEAM_ID`, `APP_IDENTIFIER`, `IOS_SCHEME` | iOS app and build settings |
| `PLAY_SERVICE_ACCOUNT_JSON` | Google Play Developer API (`supply`) |
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Upload keystore, passed to Gradle as `android.injected.signing.*` |
| `ANDROID_PACKAGE_NAME` | Play package name |

Create the App Store Connect API key once: Account Holder or Admin requests API access under **Integrations**, then creates
a team key. You can download the `.p8` once only. Team keys cover all apps and cannot be limited per app.

## Runner

The workflow asks for `runs-on: [self-hosted, kinhin-xcode]`, the Xcode image label. If your pool uses another label,
change it in `.github/workflows/mobile-release.yml`. kinhin does not store any of these secrets.

**Ruby.** fastlane 2.240 needs Ruby 3.1 or newer. The macOS system Ruby is 2.6, so the workflow runs `ruby/setup-ruby` with Ruby 3.3 before `bundle install`. Locally, use the same version (for example `rbenv` or Homebrew's `ruby@3.3`).

## Framework notes

**Flutter.** Build first, then upload. `flutter build appbundle` and `flutter build ipa` produce the artifacts. Set
`AAB_PATH` to the AAB so the Android lane skips Gradle. `FLUTTER_ROOT` must be set for the iOS deploy scripts. The
official [Flutter CD guide](https://docs.flutter.dev/deployment/cd) describes the same steps. An IPA build needs a
distribution certificate, not a development one. The iOS deployment target must be 15.0 or higher for the Xcode 26
toolchain: `flutter create` still writes 13.0, which fails with "deployment target ... is set to 13.0". The `flutter_app`
example sets 15.0 in `ios/Runner.xcodeproj/project.pbxproj`.

**React Native (bare).** The iOS and Android folders are the same as native. No official fastlane guide exists for
React Native. The layout here follows fastlane's standard setup and is not yet verified end to end. Treat the first
run as a dry run.

**Native.** Works for projects with `ios/` and `android/` folders, or with the project files at the root.

## Expo

Expo's recommended path is EAS Build and EAS Submit. Expo local builds are supported, but Expo says the toolchain is
yours to provide (fastlane included), only one platform builds per run, and `eas.json`'s `fastlane` and `ndk` keys are
ignored in local builds. `mobile-init.sh` therefore writes only `eas.json` for Expo.

To use fastlane with Expo, run `npx expo prebuild` to create the native folders, then re-run the script with
`--framework react-native`.

Caveats to check before relying on this:

- EAS Submit uploads to TestFlight. It does not release to the App Store, which the `release` lane does.
- The docs do not say whether `eas-build-pre-install` hooks run in local builds. Test it before depending on it.

## Errors you may see

| Message | Where | What to do |
| --- | --- | --- |
| `no iOS or Android project in ...; pass --framework` | `mobile-init.sh` | The folder has no detectable project. Pass `--framework`. |
| `no ios/ or android/ folder in ... for a flutter project` | `mobile-init.sh` | Run `flutter create` (or `react-native init`) first. |
| `template missing: ...` | `mobile-init.sh` | The script was copied away from the kinhin checkout. Run it from there. |
| `Missing environment variables: ASC_KEY_ID, ...` | fastlane | Set the listed secrets. The lane stops before any store call. |
| `ASC_KEY_FILEPATH does not exist` | fastlane | The `.p8` was not written. Check the "Write App Store Connect API key" step. |
| `Keystore not found at ...` | fastlane | Check `ANDROID_KEYSTORE_BASE64` and the "Write upload keystore" step. |
| `No release AAB at ...` | fastlane | Gradle did not produce the bundle. Check `AAB_PATH` and the Gradle output. |

`scripts/mobile-init-test.sh` covers the scaffolding logic. It runs in the CI docs job and in `scripts/check.sh`.

## Verification

Two scripts cover the integration:

- `scripts/mobile-init-test.sh` tests the scaffolding: detection, keep and force, dry run, and the error paths. It runs in
  `scripts/check.sh` and in CI.
- `scripts/mobile-e2e.sh` runs against a clean copy of the committed examples. It checks the templates still generate
  the committed examples, runs `bundle install` and lists the lanes, checks the secret errors in an empty environment,
  lints the generated workflows with actionlint, and confirms every fastlane option the templates use exists.
  `--with-builds` adds the native, Flutter and React Native builds and the signed-bundle check. It needs Ruby 3.1+ (set
  `RUBY_BIN` if it is not on the usual path).

The e2e script does not upload anything and does not read credentials. The store and runner steps still need a real
project. The checklist in `docs/plans/mobile-fastlane-test-checklist.md` lists what is covered and what is not.

Run this checklist on a fixture project before you trust a release:

1. `scripts/mobile-init.sh --dry-run /path/to/app` lists what would be written.
2. `bundle install` succeeds with Ruby 3.1 or newer.
3. `bundle exec fastlane lanes` lists the lanes, run from each platform's folder (see Quick start).
4. Trigger `mobile-release` with `lane: beta` against a test app and confirm the TestFlight or internal track build.
5. Re-run `mobile-init.sh` and confirm existing files are kept.

## Sources

Checked 2026-10-11. The versions and dates below are what those pages showed.

- fastlane setup: [iOS](https://docs.fastlane.tools/getting-started/ios/setup/), [Android](https://docs.fastlane.tools/getting-started/android/setup/). fastlane 2.240.1 was the latest release seen on [GitHub](https://github.com/fastlane/fastlane/releases) (2026-09-15). The Gemfile pin `~> 2.240` should be rechecked on each update.
- Actions: [`match`](https://docs.fastlane.tools/actions/match/), [`pilot`](https://docs.fastlane.tools/actions/pilot/), [`deliver`](https://docs.fastlane.tools/actions/deliver/), [`gym`](https://docs.fastlane.tools/actions/gym/), [`supply`](https://docs.fastlane.tools/actions/supply/), [`gradle`](https://docs.fastlane.tools/actions/gradle/), [`app_store_connect_api_key`](https://docs.fastlane.tools/actions/app_store_connect_api_key/)
- CI: [fastlane with GitHub Actions](https://docs.fastlane.tools/best-practices/continuous-integration/github/)
- Flutter: [Continuous Delivery](https://docs.flutter.dev/deployment/cd)
- Expo: [local builds](https://docs.expo.dev/build-reference/local-builds/), [lifecycle hooks](https://docs.expo.dev/build-reference/npm-hooks/), [EAS Submit for iOS](https://docs.expo.dev/submit/ios/)
- Google Play: [Play Developer API getting started](https://developers.google.com/android-publisher/getting_started)
- Apple: [App Store Connect API](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)

Unverified: the React Native layout, Play App Signing details, and the Xcode version needed for uploads. Apple's
help page and a third-party source disagree on that version, so check [Apple's developer news](https://developer.apple.com/news/).
