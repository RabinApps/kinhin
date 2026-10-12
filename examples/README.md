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

`scripts/mobile-e2e.sh` checks these on a clean copy of the committed examples. Run it without flags for the quick checks,
and with `--with-builds` for the builds. It needs Ruby 3.2+ (the fastlane pin resolves to 2.241, which requires it).

- Each example's workflows and fastlane files match what `kinhin mobile init` generates now (no drift).
- Each workflow parses as YAML and passes actionlint, with the `kinhin-xcode` runner label as the only exception.
- `bundle exec fastlane lanes` lists the lanes for every platform folder, and every fastlane option the templates use exists
  in the installed fastlane.
- A lane with no secrets stops with a message naming the missing variables, in an empty environment.
- The React Native install step works for yarn, pnpm, npm and no lockfile.
- With `--with-builds`:
  - `ios_native_app` builds for the simulator, and `android_native_app` builds a debug APK on Java 17.
  - `flutter_app` builds a Release device bundle for iOS with signing off, and its Android bundle through the lane is signed
    and passes `jarsigner`.
  - `RnApp` installs pods, builds for the simulator, and its Android bundle through the lane is signed.
  - A fresh `flutter create` project is scaffolded, the iOS deployment-target note appears, and its Release build passes after
    the documented fix.
  - The Expo route (`expo prebuild`, then the React Native template) builds the signed Android bundle through the lane and a
    Release device build for iOS.
- `kinhin mobile init` exits 2 for an unknown framework, a missing folder, a folder with no project, and a bare `kinhin mobile`.

Not verified: any store upload, `match` with real certificates, and the workflows running on a `kinhin-xcode` runner. Those
need the owner's accounts and a runner. The `eas.json` for Expo is not checked against EAS Build, which needs a linked project.

## Regenerate

The Flutter example's iOS deployment target is 15.0. `flutter create` still writes 13.0, which Xcode 26 rejects.

`ios_native_app` is defined by `ios_native_app/project.yml`. Run `xcodegen generate` in that folder after changing it.
The other apps came from the framework CLIs listed above.
