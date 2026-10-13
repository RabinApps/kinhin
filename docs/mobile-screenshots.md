# Store screenshots with fastlane

`kinhin mobile init` adds a `screenshots` lane to the iOS and Android projects. It captures localized screenshots from
UI tests (iOS: `snapshot`; Android: `screengrab`), can frame them with frameit, and can upload them to the stores. Upload
is off unless you turn it on. This page covers setup, the folder layout, every setting you can change, and what has been
verified.

[← Back to mobile releases](mobile-fastlane.md) · [Tutorial](mobile-fastlane-tutorial.md) · [Troubleshooting](mobile-fastlane-troubleshooting.md)

## What you get

| Platform | Capture | Settings file | Where the test lives |
| --- | --- | --- | --- |
| iOS (native, Flutter, React Native) | `snapshot` runs UI tests on simulators | `fastlane/Snapfile`, `fastlane/Framefile.json` | `UITests/` next to the app (see [step 1](#ios-set-up-the-ui-test-target)) |
| Android (native, Flutter, React Native) | `screengrab` runs instrumented tests on an emulator or device | `fastlane/Screengrabfile` | `app/src/androidTest/java/screenshots/` |

`kinhin mobile init` writes the settings, the sample tests and the lane. It does not edit your Xcode project or your Gradle
files, because those are easy to break from a script. The steps that need them are below.

## Run it

```bash
# iOS: from the folder that holds fastlane/ (ios/ for Flutter and React Native)
bundle exec fastlane screenshots

# Android: from the folder that holds fastlane/ (the app root for native; android/ for Flutter and React Native).
# Set the application ID first; the lane builds the two APKs itself.
ANDROID_PACKAGE_NAME=com.example.yourapp bundle exec fastlane screenshots
```

Add `FRAME_SCREENSHOTS=1` to frame the images, or `UPLOAD_SCREENSHOTS=1` to upload them. Both are described below.

The CI workflow runs the same lane when you start it by hand: choose `screenshots` as the lane. The Android job does not run
for the `release` choice, because there is no Android release lane yet.

### Settings from CI

The workflow passes these repository variables (**Settings**, then **Secrets and variables**, then **Variables**) into the
lane. An empty or unset variable means the default. They are variables, not secrets, so do not put anything sensitive in them.

| Variable | Used by | Effect |
| --- | --- | --- |
| `FRAME_SCREENSHOTS` | iOS | `1` runs frameit (see [Frames](#frames-optional)) |
| `UPLOAD_SCREENSHOTS` | iOS, Android | `1` uploads the screenshots (see [Upload](#upload-optional)) |
| `SNAPSHOT_DEVICES` | iOS | Comma-separated simulator names |
| `SNAPSHOT_LANGUAGES` | iOS | Comma-separated languages (default `en-US`) |
| `SCREENGRAB_LOCALES` | Android | Comma-separated locales (default `en-US`) |
| `SCREENGRAB_DEVICE_TYPE` | Android | `phone`, `sevenInch`, `tenInch`, `tv` or `wear` |

Gitea, Forgejo and GitLab name their variables differently, so check their docs before you rely on these.

### Artifacts

The VM running the job is deleted when the job ends, so the screenshots would disappear with it. The workflow therefore
uploads them as a CI artifact (`ios-screenshots` or `android-screenshots`, kept for 14 days) after the lane, even when the lane
fails. Find the artifact on the workflow run's page. The artifact is visible to everyone who can read the run, so use test
accounts and fake data in the app's screens.

The Android job runs on the same macOS `kinhin-xcode` runner as iOS. screengrab needs an Android emulator or a device on that
runner, which the runner image has to provide. We have not verified that setup on a runner.

## iOS: set up the UI test target

fastlane's snapshot needs a UI test target in the Xcode project. The scaffold writes the test sources; you add the target once.

1. In Xcode, add a **UI Testing Bundle** target (for example `MyAppUITests`) that tests your app.
2. Add `UITests/SnapshotHelper.swift` and `UITests/ScreenshotTests.swift` to that target. The helper is fastlane's
   own file, copied unchanged.
3. Make sure the scheme you use runs the UI tests. Snapshot uses the scheme in `Snapfile`, from `SNAPSHOT_SCHEME` or
   `IOS_SCHEME`. The scheme's Test action must include the UI test target.
4. Keep the test class `@MainActor`. The snapshot helper functions are main-actor isolated, so a test class without it fails
   to build with "Call to main actor-isolated global function 'setupSnapshot'". We hit this with the current Xcode.

Our example does this in XcodeGen. `examples/ios_native_app/project.yml` has the target and the scheme:

```yaml
  IosNativeAppUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: [UITests]
    dependencies:
      - target: IosNativeApp
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: com.example.iosnativeapp.uitests
        TEST_TARGET_NAME: IosNativeApp
schemes:
  IosNativeApp:
    build:
      targets:
        IosNativeApp: all
        IosNativeAppUITests: [test]
    test:
      targets:
        - IosNativeAppUITests
```

Flutter and React Native apps have a `Runner` or `<App>` project under `ios/` that you open in Xcode. Add the target there the same
way; the Flutter integration-test docs do not cover screenshots, so the native UI test target is the route.

### Customize iOS

`fastlane/Snapfile` reads these, each with a default:

| Setting | Environment variable | Default | Notes |
| --- | --- | --- | --- |
| `scheme` | `SNAPSHOT_SCHEME`, then `IOS_SCHEME` | none | Must run the UI tests |
| `devices` | `SNAPSHOT_DEVICES` (comma separated) | `iPhone 17e` | Names from `xcrun simctl list devices available`. Without a device list, snapshot can boot several simulators, which is slow |
| `languages` | `SNAPSHOT_LANGUAGES` (comma separated) | `en-US` | One folder per language |
| `output_directory` | edit the file | `./fastlane/screenshots` | Read against the project folder |
| `clear_previous_screenshots` | edit the file | `true` | A deleted screen does not stay in the upload |
| `stop_after_first_error` | edit the file | `false` | |

Empty values from CI are treated as unset. Add `testplan`, `only_testing` or any other snapshot option to the file as you
need. The fastlane page lists them all.

### iOS output

A run writes one PNG per `snapshot("name")` call and language, named after the device:

```
fastlane/screenshots/
  en-US/
    iPhone 17e-01-home.png
  screenshots.html
```

We verified this layout by running the lane on an iPhone 17e simulator. The lane checks that at least one PNG exists, because
snapshot can exit 0 when the tests fail to build or run. The lane then stops with a message instead of passing silently.

## React Native iOS: set up

The React Native iOS example needs three things beyond the UI test target:

- **Build the JavaScript into the Debug app.** The Debug simulator build skips bundling, so run the lane with
  `FORCE_BUNDLING=1 bundle exec fastlane screenshots`. Without it the app shows a red "No script URL" screen.
- **Adopt the iOS 27 scene lifecycle.** Add `UIApplicationSceneManifest` to `Info.plist` and create the window in a
  `SceneDelegate`. Without it the UI test crashes with SIGTRAP.
- **Pass the language to the app.** `SnapshotHelper` sets `-AppleLanguages`, but React Native's `Settings.get('AppleLanguages')`
  does not return it. The UI test passes its own launch argument, and the app reads it:

  ```swift
  app.launchArguments += ["-KinhinLanguage", Snapshot.deviceLanguage]
  ```

  ```ts
  const launched = Settings.get('KinhinLanguage') as string | undefined;
  ```

The example `examples/RnApp` does all three. Use a Release build for store screenshots, since the Debug build shows a
warning banner.

## Android: set up the instrumented tests

screengrab needs these in the Android project, once:

1. **Gradle dependencies** in `app/build.gradle.kts`, with `testInstrumentationRunner` set. Versions are the current releases
   on Google's and Maven Central's repositories:

   ```kotlin
   android {
       defaultConfig {
           testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
       }
   }

   dependencies {
       androidTestImplementation("androidx.test:runner:1.7.0")
       androidTestImplementation("androidx.test.ext:junit:1.3.0")
       androidTestImplementation("junit:junit:4.13.2")
       androidTestImplementation("tools.fastlane:screengrab:2.1.1")
   }
   ```

2. **`android.useAndroidX=true`** in `gradle.properties`. The AndroidX test libraries fail to build without it.
3. **Debug permissions.** `app/src/debug/AndroidManifest.xml` must declare the five permissions screengrab needs. The scaffold
   writes them. If that file already exists (Flutter always has one, with `INTERNET`), the scaffold keeps it and prints a note;
   merge the permissions in by hand:

   ```xml
   <uses-permission android:name="android.permission.DISABLE_KEYGUARD" />
   <uses-permission android:name="android.permission.WAKE_LOCK" />
   <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
   <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
   <uses-permission android:name="android.permission.CHANGE_CONFIGURATION" />
   ```

The sample test is `app/src/androidTest/java/screenshots/ScreenshotTest.java`. It launches the app's launcher activity, waits
for the first frame, and calls `Screengrab.screenshot("01-home")`. The `LocaleTestRule` class rule switches the locale for each
entry in `Screengrabfile`. Add a test method per screen.

The example `examples/android_native_app` has all of this. `./gradlew assembleDebugAndroidTest` compiles it, and the e2e checks
that.

### Customize Android

`fastlane/Screengrabfile` reads these:

| Setting | Environment variable | Default | Notes |
| --- | --- | --- | --- |
| `app_package_name` | `ANDROID_PACKAGE_NAME` | none, so it must be set | The `applicationId` of the app under test. Without it screengrab stops with `No value found for 'app_package_name'` |
| `locales` | `SCREENGRAB_LOCALES` (comma separated) | `en-US` | One folder per locale |
| `device_type` | `SCREENGRAB_DEVICE_TYPE` | `phone` | `phone`, `sevenInch`, `tenInch`, `tv` or `wear` |
| `output_directory` | edit the file | `./fastlane/metadata/android` | Google Play's metadata layout |
| `clear_previous_screenshots` | edit the file | `true` | |
| `app_apk_path`, `tests_apk_path` | edit the file | `app/build/outputs/apk/...` | The APKs the lane builds with Gradle. screengrab does not build them |

The screenshots lane runs `assemble` and `assembleDebugAndroidTest` before screengrab. Without the two APK paths screengrab
asks for them in a prompt, which fails in CI.

### Android output

A run of `fastlane screenshots` with `en-US` and the default device type writes:

```
fastlane/metadata/android/
  en-US/images/phoneScreenshots/01-home_<timestamp>.png
  screenshots.html
```

screengrab appends a timestamp to each file name, so `Screengrab.screenshot("01-home")` writes `01-home_<timestamp>.png`.
`screenshots.html` is a report that screengrab writes next to the locale folders; it is not an upload file. Both are
ignored by `examples/.gitignore`.

## Locales

Set the list of languages and the lane captures each one, in its own folder:

```bash
SNAPSHOT_LANGUAGES=en-US,fr-FR bundle exec fastlane screenshots   # iOS
SCREENGRAB_LOCALES=en-US,fr-FR bundle exec fastlane screenshots   # Android
```

Your app has to show different text for each language. On iOS that means a String Catalog (`Localizable.xcstrings`) with
a translation for each language; on Android, `values-fr/strings.xml` next to `values/strings.xml`. Otherwise every locale
folder holds the same English screen. The examples show the pattern: `examples/ios_native_app/App/Localizable.xcstrings`
and `examples/android_native_app/app/src/main/res/values-fr/strings.xml`.

## Frames (optional)

Set `FRAME_SCREENSHOTS=1` and the lane runs frameit on the screenshots folder. Settings go in `fastlane/Framefile.json`. The
scaffold writes valid JSON: a black frame, 50-pixel padding, and no entries under `data`.

**Status: frames are implemented but not yet working on Homebrew's ImageMagick 7.1.2-33.** frameit calls
`magick mogrify -rotate 0 <file>` with no output format, and that build fails with "no encode delegate for this image format
`'". The same operation with `-format png` succeeds. Upstream reports it as
[ImageMagick issue #9011](https://github.com/ImageMagick/ImageMagick/issues/9011), with a fix committed on October 11, 2026.
Until a Homebrew release includes that fix, frames will stop with an error. The lane checks whether frameit changed any
screenshot, because frameit can exit 0 without framing anything.

Things to know:

- **ImageMagick is installed for you.** When frames are on and no `magick` or `convert` command is available, the lane runs
  `brew install imagemagick`. It stops with a clear message if Homebrew is missing, since installing Homebrew needs an admin
  password. Frames also need the first-run download of the device frames.
- **Framed images without titles keep the full device resolution**, and the frameit docs say App Store Connect cannot take
  them. The lane therefore refuses to upload framed images unless you set `ALLOW_FRAMED_UPLOAD=1`, which you should do only once
  `Framefile.json` has titles.

## Upload (optional)

Set `UPLOAD_SCREENSHOTS=1` to upload. Upload is off by default, and the release lanes keep their existing skip settings.

- **iOS** uses `upload_to_app_store` with `skip_binary_upload`, `skip_metadata` and `skip_app_version_update`, and reads
  `./fastlane/screenshots`. `overwrite_screenshots` is set to true; see the deliver docs for its exact behaviour.
- **Android** uses `upload_to_play_store` with the APK and AAB and metadata uploads skipped, and reads
  `./fastlane/metadata/android`. It needs `PLAY_SERVICE_ACCOUNT_JSON`.

The upload settings are checked against fastlane 2.241.0 by the e2e. Nothing in this repository calls the stores; you run the
upload yourself, with your own credentials. See [credentials](mobile-credentials.md).

## Other frameworks

- **Capacitor and Ionic:** the screenshot files are scaffolded under `ios/UITests/` and `android/app/src/androidTest/`, but the
  Xcode UI test target (`App`'s UI tests in `ios/App/App.xcodeproj`) and the Gradle test dependencies are added by hand, as
  for React Native and Flutter.
- **Kotlin Multiplatform:** the UI test target goes in `iosApp/` (`iosApp/UITests/`), and the instrumented tests go in
  `androidApp/src/androidTest/`. The Android module is `androidApp`, not `app`, so the paths have no `app/` prefix.
- **.NET MAUI:** no screenshot files. MAUI does not generate UI test projects, so this stays out of the scaffold.

## In a launch video

The screenshots can feed a launch cut. `examples/mobile-30s` shows them with a locale beat, and `video.yml` captures them in a
`mobile-capture` job for a look that sets `screens`. See [CI video](ci-video.md#store-screenshots-in-the-mobile-cut) and
[making a video](making-a-video.md#screenshots-as-a-scene).

## What is verified

- **iOS capture:** `fastlane screenshots` ran the UI test on an iPhone 17e simulator, wrote `fastlane/screenshots/en-US/iPhone 17e-01-home.png`,
  and the image shows the app's first screen. The lane exits 0 only when at least one PNG exists.
- **iOS build:** the UI test target compiles with the `@MainActor` requirement.
- **Android capture:** `fastlane screenshots` ran on a Pixel 9 emulator (Android 37, arm64) and wrote
  `fastlane/metadata/android/en-US/images/phoneScreenshots/01-home_<timestamp>.png` at 1080 x 2424. The lane exits 0 only when at least one PNG exists.
- **Locales:** both platforms captured `en-US` and `fr-FR` in one run, each in its own folder, and the French images show French text.
  iOS wrote `fastlane/screenshots/fr-FR/iPhone 17e-01-home.png`; Android wrote `fastlane/metadata/android/fr-FR/images/phoneScreenshots/`.
  The sample apps in `examples/` translate their one string, so the locale switch is visible in the image.
- **Flutter iOS capture:** `fastlane screenshots` ran on iPhone 17e and wrote `en-US` and `fr-FR` 1170 x 2532 PNGs. Each shows the greeting in its language.
- **React Native iOS capture:** `fastlane screenshots` ran on iPhone 17e and wrote `en-US` and `fr-FR` 1170 x 2532 PNGs. Each shows the greeting in its language. The Debug build needs `FORCE_BUNDLING=1` (see [React Native iOS](#react-native-ios-set-up)).
  The French image was taken before the sample showed French text, so it does not prove the locale switch.
- **Flutter and React Native Android capture:** both locales show the greeting in the right language, on a Pixel 9 emulator, for
  both examples. The React Native lane needs Metro running and `adb reverse tcp:8081 tcp:8081` (the Debug build loads its
  JavaScript from Metro). The React Native debug manifest declares the Bluetooth permissions the sample asks for.
- **Android build:** `assembleDebugAndroidTest` compiles the instrumented test with the dependencies above.
- **Options:** every snapshot, screengrab, frameit and screenshot-upload option the templates use exists in fastlane 2.241.0.
- **frameit prerequisite:** frameit stops without ImageMagick. The lane installs it when frames are on.

## What is not verified

- **Frames** end to end. Blocked by [ImageMagick #9011](https://github.com/ImageMagick/ImageMagick/issues/9011) until a release contains the fix.
  The framed output's file name is also unknown.
- **Multiple devices** on iOS. The iOS runs used one simulator (iPhone 17e); the layout for several devices is from the snapshot docs.
- **Debug banner.** React Native Debug builds show an "Open debugger to view warnings" banner in the screenshots. Use a Release build for store screenshots.
- **`simctl diagnose` can hang after a React Native test.** xcodebuild starts it after each test. Kill it and the lane continues.
- **Flutter iOS debug simulator build.** `flutter build ios --simulator --debug` fails on this toolchain (see
  [troubleshooting](mobile-fastlane-troubleshooting.md#screenshots)); the example builds with `xcodebuild` and `ARCHS=arm64`.
- **Uploads** against real stores. Not run, by decision.
