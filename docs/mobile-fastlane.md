# Mobile releases with fastlane

This is opt-in. kinhin's runners, configuration and commands work exactly as before unless you run `kinhin mobile init`
in a project. Running it only adds files to that project: fastlane lanes, a `Gemfile`, and a CI workflow. kinhin's own
config is not read or changed by it.

Scaffold fastlane into an iOS, Android, Flutter, React Native, Expo or Capacitor project, and run store uploads from a kinhin
runner. `kinhin mobile init` writes the lanes, a pinned Gemfile and a manual release workflow. Nothing is uploaded until you
trigger the workflow.

[← Back to toolchains](toolchains.md)

## Quick start

Install kinhin, then run this from anywhere, with the project folder as the argument. The [tutorial](mobile-fastlane-tutorial.md) walks through a first build end to end, the [credentials](mobile-credentials.md) page covers each secret, and [store screenshots](mobile-screenshots.md) covers the `screenshots` lane:

```bash
kinhin mobile init /path/to/your/app
```

It detects the framework, then writes only the files that are missing:

| Project | Detected by | Writes |
| --- | --- | --- |
| Flutter | `pubspec.yaml` | `Gemfile`, `ios/fastlane/`, `android/fastlane/`, `.github/workflows/mobile-release.yml` |
| React Native (bare) | `"react-native"` in `package.json` | same as Flutter |
| Capacitor / Ionic | `"@capacitor/core"` in `package.json` | same as Flutter. Each platform's CI job runs `npm run build` and `npx cap sync`. |
| Kotlin Multiplatform | `iosApp/`, Gradle settings, and the multiplatform plugin in a build file | `iosApp/fastlane/`, `androidApp/fastlane/`, workflow. The Xcode build phase builds the shared framework. |
| .NET MAUI | a `.csproj` with `<UseMaui>true</UseMaui>` (root or one folder down) | `ios/fastlane/`, `android/fastlane/`, workflow. `dotnet publish` builds and signs the artifacts. |
| Expo | `"expo"` in `package.json` | `eas.json` only. Expo uses EAS by default (see [Expo](#expo)). |
| Native iOS | `ios/` or `*.xcodeproj` / `*.xcworkspace` | `Gemfile`, `fastlane/` (or `ios/fastlane/`), workflow |
| Native Android | `android/` or `settings.gradle(.kts)` | `Gemfile`, `fastlane/` (or `android/fastlane/`), workflow |

Flags:

- `--framework ios|android|flutter|react-native|expo|capacitor|kmp|maui|native` overrides detection.
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
| iOS | `screenshots` | `snapshot` (UI tests on a simulator) → optional `frameit` (`FRAME_SCREENSHOTS=1`) → optional upload (`UPLOAD_SCREENSHOTS=1`). See [store screenshots](mobile-screenshots.md). |
| Android | `screenshots` | `screengrab` (instrumented tests on an emulator) → optional upload (`UPLOAD_SCREENSHOTS=1`). See [store screenshots](mobile-screenshots.md). |
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

Create the App Store Connect API key once: the Account Holder requests API access under **Integrations**, then an Account
Holder or Admin creates a team key. You can download the `.p8` once only. Team keys cover all apps and cannot be limited per app.

## Runner

The workflow asks for `runs-on: [self-hosted, kinhin-xcode]`, the Xcode image label. If your pool uses another label,
change it in `.github/workflows/mobile-release.yml`. kinhin does not store any of these secrets.

**Ruby.** fastlane 2.241, which the `~> 2.240` pin resolves to, needs Ruby 3.2 or newer. The macOS system Ruby is 2.6, so the workflow runs `ruby/setup-ruby` with Ruby 3.3 before `bundle install`. Locally, use the same version (for example `rbenv` or Homebrew's `ruby@3.3`).

## Framework notes

The generated CI jobs run the framework's own setup before the lanes, so a clean checkout builds without manual steps.
A monorepo app works too; see [Monorepos](#monorepos).

**Flutter.** The jobs install the Flutter SDK (`subosito/flutter-action`) and run `flutter pub get`, which also writes
`android/local.properties`. On iOS they run `flutter build ios --config-only --release` before CocoaPods, so the
generated Flutter config exists when the Xcode project is built. The Android lane then builds the signed bundle with
Gradle, using the same signing properties as the native projects, and finds it at `build/app/outputs/bundle/release/`.
Set `AAB_PATH` only when another step has already built a bundle; then Gradle is skipped. An IPA build needs a
distribution certificate, not a development one. The iOS deployment target must be 15.0 or higher for the Xcode 26
toolchain: `flutter create` still writes 13.0, which fails with "deployment target ... is set to 13.0". The `flutter_app`
example sets 15.0 in `ios/Runner.xcodeproj/project.pbxproj`.

**React Native (bare).** The jobs set up Node 22 and install dependencies before CocoaPods and Gradle run: `npm ci` when
there is a `package-lock.json`, `yarn install --frozen-lockfile` when there is a `yarn.lock`, `pnpm install --frozen-lockfile`
when there is a `pnpm-lock.yaml`, and `npm install` otherwise.
No official fastlane guide exists for React Native. The layout follows fastlane's standard setup. The e2e checks the same
steps (npm, pod install, a simulator build and the signed Android bundle), but a real store upload is still unverified.
The Android build needs `ANDROID_HOME` on the runner, or an `android/local.properties` with `sdk.dir`.

**Native.** Works for projects with `ios/` and `android/` folders, or with the project files at the root.

## Capacitor and Ionic

Capacitor keeps its iOS project in `ios/App/App.xcodeproj`, one level below the fastlane folder. The CI job exports
`IOS_PROJECT=App/App.xcodeproj` for that, so the iOS lanes find the project. For a local run, set it yourself:

```bash
cd ios
IOS_PROJECT=App/App.xcodeproj bundle exec fastlane beta
```

Capacitor 8's Android library needs Java 21, so the Android job uses Java 21 for Capacitor projects (the other frameworks use
Java 17). Capacitor 8 resolves its iOS packages with Swift Package Manager, so there is no Podfile.

Capacitor generates `ios/App/App.xcodeproj`, and the kinhin repository ignores `*.xcodeproj` for its XcodeGen examples, so a
Capacitor project that lives in a kinhin repository needs an exception in its `.gitignore`. `examples/capacitor_app` shows it.

## Kotlin Multiplatform

The Android module is `androidApp` under a Gradle root one folder above `androidApp/`. The CI jobs set
`ANDROID_GRADLE_DIR=..` and `ANDROID_GRADLE_MODULE=androidApp`, so the lanes build `:androidApp:bundle`. For a local run, set
them yourself. The iOS build runs the Xcode build phase, which calls `./gradlew :shared:embedAndSignAppleFrameworkForXcode`.
Run Gradle with JDK 17 (JDK 26 fails with Kotlin), and export `JAVA_HOME` before a plain `./gradlew` run.

## .NET MAUI

fastlane signs nothing for MAUI. The lanes call `dotnet publish` with `MAUI_PROJECT` set to the `.csproj` (the CI jobs set it).
The iOS lane runs after `match`, so it can sign with the certificate match installed. Set `MAUI_CODESIGN_KEY` (the signing
identity) and `MAUI_PROVISIONING_PROFILE` (the profile name) as repository variables. The Android lane signs the AAB with the
upload keystore. Screenshots are not scaffolded for MAUI, because MAUI does not generate UI test projects.

## Expo

Expo's recommended path is EAS Build and EAS Submit. Expo local builds are supported, but Expo says the toolchain is
yours to provide (fastlane included), only one platform builds per run, and `eas.json`'s `fastlane` and `ndk` keys are
ignored in local builds. `kinhin mobile init` therefore writes only `eas.json` for Expo.

To use fastlane with Expo, create the native folders, then scaffold them as a React Native project:

```bash
npm install
npx expo prebuild --no-install   # creates ios/ and android/ (both platforms when no --platform is given)
kinhin mobile init --framework react-native .
```

The e2e runs this route: it builds the Android bundle through the lane with a signing keystore, and runs `pod install` and
a Release device build for iOS. Expo's own `--platform` flag takes one value, so leave it out to get both platforms.

Caveats to check before relying on this:

- EAS Submit uploads to TestFlight. The iOS `release` lane uploads a build to App Store Connect without submitting it for review.
- The docs do not say whether `eas-build-pre-install` hooks run in local builds. Test it before depending on it.

## Monorepos

`kinhin mobile init` writes the workflow paths relative to the git repository that contains the project. For an app at
`apps/mobile` in a monorepo, the jobs run `working-directory: apps/mobile/ios` and the setup steps run in `apps/mobile`.
Run it from the app folder, or pass the path: `kinhin mobile init apps/mobile`. A project with no git repository above it
gets paths from its own root.

## Errors you may see

The full list, with the cause and the fix for each, is in the [troubleshooting page](mobile-fastlane-troubleshooting.md). The
most common ones:

| Message | Where | What to do |
| --- | --- | --- |
| `no iOS or Android project in ...; pass --framework` | `kinhin mobile init` | The folder has no detectable project. Pass `--framework`. |
| `no ios/ or android/ folder in ... for a flutter project` | `kinhin mobile init` | Run `flutter create` (or `react-native init`) first. |
| `Missing environment variables: ASC_KEY_ID, ...` | fastlane | Set the listed secrets. The lane stops before any store call. |
| `ASC_KEY_FILEPATH does not exist` | fastlane | The `.p8` was not written. Check the "Write App Store Connect API key" step. |
| `Keystore not found at ...` | fastlane | Check `ANDROID_KEYSTORE_BASE64` and the "Write upload keystore" step. |
| `No release AAB at ...` | fastlane | Gradle did not produce the bundle. Check `AAB_PATH` and the Gradle output. |

The `MobileScaffoldTests` Swift tests cover the scaffolding logic. They run in `swift test`, which CI and `scripts/check.sh` both run.

## Verification

Two checks cover the integration:

- The `MobileScaffoldTests` Swift tests cover the scaffolding: detection, keep and force, dry run, monorepo paths and the
  error paths. They run in `swift test`, which `scripts/check.sh` and CI both run.
- `scripts/mobile-e2e.sh` runs against a clean copy of the committed examples. It checks the templates still generate
  the committed examples, runs `bundle install` and lists the lanes, checks the secret errors in an empty environment,
  lints the generated workflows with actionlint, and confirms every fastlane option the templates use exists.
  `--with-builds` adds the native, Flutter and React Native builds and the signed-bundle check. It needs Ruby 3.2+ (set
  `RUBY_BIN` if it is not on the usual path). Building the binary needs Swift; the builds need JDK 17, an Android SDK,
  Xcode, Flutter, XcodeGen, and `jarsigner` (part of the JDK). The React Native steps need npm and CocoaPods.

The e2e script does not upload anything and does not read credentials. The store and runner steps still need a real
project. The checklist in `docs/plans/mobile-fastlane-test-checklist.md` lists what is covered and what is not.

Run this checklist on a fixture project before you trust a release:

1. `kinhin mobile init --dry-run /path/to/app` lists what would be written.
2. `bundle install` succeeds with Ruby 3.2 or newer.
3. `bundle exec fastlane lanes` lists the lanes, run from each platform's folder (see Quick start).
4. Trigger `mobile-release` with `lane: beta` against a test app and confirm the TestFlight or internal track build.
5. Re-run `kinhin mobile init` and confirm existing files are kept.

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
