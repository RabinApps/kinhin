# Example apps for the fastlane integration

Five small, real apps, one per supported project shape. Use them to try `kinhin mobile init` and the fastlane
lanes without touching a production project.

| App | Shape | Created with | Lanes live in |
| --- | --- | --- | --- |
| `flutter_app` | Flutter | `flutter create --platforms=ios,android` | `ios/fastlane/`, `android/fastlane/` |
| `RnApp` | React Native (bare) | `@react-native-community/cli init` | `ios/fastlane/`, `android/fastlane/` |
| `expo_app` | Expo | `create-expo-app --template blank` | `eas.json` only (EAS is the default) |
| `ios_native_app` | Native iOS (SwiftUI) | `project.yml` with XcodeGen | `fastlane/` at the project root |
| `android_native_app` | Native Android (Kotlin) | hand-written Gradle project | `fastlane/` at the project root |

## Try it

Scaffold an app (existing files are kept, so re-running is safe):

```bash
kinhin mobile init examples/flutter_app
```

Then, from the folder that holds `fastlane/`:

```bash
bundle install
bundle exec fastlane lanes
```

For Flutter and React Native, run this from `ios/` or `android/`. For the native apps, run it from the app folder.

## What was verified

- `the `MobileScaffoldTests` Swift tests` covers detection, scaffolding, keep and force, dry run, and the error paths.
- A lane with no secrets stops with a message naming the missing variables (`fastlane ios beta`, `fastlane android beta`).

- `kinhin mobile init` scaffolds all five apps. The CI workflow gets only the jobs that match the project, and
  Expo gets `eas.json` only.
- `bundle exec fastlane lanes` lists the lanes for every platform, using fastlane 2.241.0 on Ruby 3.3.
- `ios_native_app` builds for the iOS simulator (`xcodebuild ... CODE_SIGNING_ALLOWED=NO`).
- `android_native_app` builds the debug APK with Gradle 8.14 on Java 17. Gradle 8.14 does not run on Java 26.

Not verified: running the lanes end to end. That needs App Store Connect, Play and match credentials, and the lanes
upload to real stores. The React Native and Flutter iOS builds also need CocoaPods and signing, so they were not built.

## Regenerate

The Flutter example's iOS deployment target is 15.0. `flutter create` still writes 13.0, which Xcode 26 rejects.

`ios_native_app` is defined by `ios_native_app/project.yml`. Run `xcodegen generate` in that folder after changing it.
The other apps came from the framework CLIs listed above.
