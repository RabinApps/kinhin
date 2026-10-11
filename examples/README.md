# Example apps for the fastlane integration

Five small, real apps, one per supported project shape. Use them to try `scripts/mobile-init.sh` and the fastlane
lanes without touching a production project.

| App | Shape | Created with | Lanes live in |
| --- | --- | --- | --- |
| `flutter_app` | Flutter | `flutter create --platforms=ios,android` | `ios/fastlane/`, `android/fastlane/` |
| `RnApp` | React Native (bare) | `@react-native-community/cli init` | `ios/fastlane/`, `android/fastlane/` |
| `expo_app` | Expo | `create-expo-app --template blank` | `eas.json` only (EAS is the default) |
| `ios_native_app` | Native iOS (SwiftUI) | `project.yml` with XcodeGen | `fastlane/` at the project root |
| `android_native_app` | Native Android (Kotlin) | hand-written Gradle project | `fastlane/` at the project root |

## Try it

From the repository root, scaffold an app (existing files are kept, so re-running is safe):

```bash
scripts/mobile-init.sh examples/flutter_app
```

Then, from the folder that holds `fastlane/`:

```bash
bundle install
bundle exec fastlane lanes
```

For Flutter and React Native, run this from `ios/` or `android/`. For the native apps, run it from the app folder.

## What was verified

- `scripts/mobile-init.sh` scaffolds all five apps. The CI workflow gets only the jobs that match the project, and
  Expo gets `eas.json` only.
- `bundle exec fastlane lanes` lists the lanes for every platform, using fastlane 2.241.0 on Ruby 3.3.
- `ios_native_app` builds for the iOS simulator (`xcodebuild ... CODE_SIGNING_ALLOWED=NO`).
- `android_native_app` builds the debug APK with Gradle 8.14 on Java 17. Gradle 8.14 does not run on Java 26.

Not verified: running the lanes end to end. That needs App Store Connect, Play and match credentials, and the lanes
upload to real stores. The React Native and Flutter iOS builds also need CocoaPods and signing, so they were not built.

## Regenerate

`ios_native_app` is defined by `ios_native_app/project.yml`. Run `xcodegen generate` in that folder after changing it.
The other apps came from the framework CLIs listed above.
