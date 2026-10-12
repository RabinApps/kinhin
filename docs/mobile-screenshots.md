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

# Android: from the folder that holds fastlane/ (the app root for native; android/ for Flutter and React Native)
bundle exec fastlane screenshots
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
| `devices` | `SNAPSHOT_DEVICES` (comma separated) | not set: snapshot chooses | Names from `xcrun simctl list devices available` |
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
| `app_package_name` | `ANDROID_PACKAGE_NAME` | none | The `applicationId` of the app under test |
| `locales` | `SCREENGRAB_LOCALES` (comma separated) | `en-US` | One folder per locale |
| `device_type` | `SCREENGRAB_DEVICE_TYPE` | `phone` | `phone`, `sevenInch`, `tenInch`, `tv` or `wear` |
| `output_directory` | edit the file | `./fastlane/metadata/android` | Google Play's metadata layout |
| `clear_previous_screenshots` | edit the file | `true` | |

### Android output

The docs say screenshots go to `fastlane/metadata/android` in the directory where you ran `screengrab`. The per-locale
`images/` folders that supply reads are described in its docs, but we have not yet run screengrab to confirm the exact
folders; see [what is not verified](#what-is-not-verified).

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

## What is verified

- **iOS capture:** `fastlane screenshots` ran the UI test on an iPhone 17e simulator, wrote `fastlane/screenshots/en-US/iPhone 17e-01-home.png`,
  and the image shows the app's first screen. The lane exits 0 only when at least one PNG exists.
- **iOS build:** the UI test target compiles with the `@MainActor` requirement.
- **Android build:** `assembleDebugAndroidTest` compiles the instrumented test with the dependencies above.
- **Options:** every snapshot, screengrab, frameit and screenshot-upload option the templates use exists in fastlane 2.241.0.
- **frameit prerequisite:** frameit stops without ImageMagick. The lane installs it when frames are on.

## What is not verified

- **Android capture.** This Mac's Pixel 9 emulator image is incomplete, so screengrab has not run here. Compile is verified; a capture run is not.
- **Frames** end to end. Blocked by [ImageMagick #9011](https://github.com/ImageMagick/ImageMagick/issues/9011) until a release contains the fix.
  The framed output's file name is also unknown.
- **Folder layouts for multiple locales and devices** on both platforms. The iOS layout above is from a single-language run.
- **Flutter and React Native capture.** They use the same native targets, and the scaffold writes the files, but we have not added
  a UI test target to a Flutter or React Native project and run it.
- **Uploads** against real stores. Not run, by decision.
