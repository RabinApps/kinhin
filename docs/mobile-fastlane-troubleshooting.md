# Mobile releases: troubleshooting

The failures we have hit while building and testing the integration, with the cause and the fix. Each heading is the
text of the error, so search for it.

[← Back to mobile releases](mobile-fastlane.md) · [Tutorial](mobile-fastlane-tutorial.md) · [Credentials](mobile-credentials.md)

## Setup and scaffolding

### `no iOS or Android project in ...; pass --framework`

`kinhin mobile init` found neither an `ios/` nor an `android/` folder, nor an Xcode project or Gradle settings file, and no
`pubspec.yaml` or `expo`/`react-native` entry in `package.json`. Run it in the project folder, or pass `--framework`.

### `no ios/ or android/ folder in ... for a flutter project`

A Flutter or React Native project needs its native folders. Create them with `flutter create .` or
`npx react-native init`, or generate them for Expo with `npx expo prebuild`, then run `kinhin mobile init` again.

### `Gemfile exists but cannot be read`

The project's `Gemfile` exists but is not readable by your user. Fix its permissions and run the command again.

### `bundler could not find compatible versions for gem "ruby"`

fastlane 2.240 needs Ruby 3.1 or newer. The macOS system Ruby is 2.6, so `bundle install` fails with that message. Use
Ruby 3.3, for example from Homebrew (`brew install ruby@3.3`), and run `bundle install` from a shell where that Ruby is first
on your PATH. CI sets it up with `ruby/setup-ruby`.

### Expo: the EAS config is there, but there is no `fastlane` folder

That is expected. Expo uses EAS Build and EAS Submit by default, and `kinhin mobile init` writes `eas.json` only. For
fastlane, run `npx expo prebuild`, then `kinhin mobile init --framework react-native`. The reference page has the details.

## Local builds

### `deployment target ... is set to 13.0`

Xcode 26 needs an iOS deployment target of 15.0 or higher. `flutter create` still writes 13.0, and `kinhin mobile init` prints a note naming the file when it finds a lower value. Change
`IPHONEOS_DEPLOYMENT_TARGET` in `ios/Runner.xcodeproj/project.pbxproj` to 15.0 (and the `platform :ios` line in the
Podfile, if there is one).

### `Binary ... does not contain architectures "arm64 x86_64"` (Flutter, simulator)

The Flutter Debug simulator build does not work with the Flutter version we tested (3.41): `Flutter.framework` has no
simulator architectures, with or without `--config-only`, or `flutter build ios --simulator --debug`. The release lane
does not use the simulator. Check the iOS side with the Release device build, which is what the lane's archive step runs:
`xcodebuild -workspace Runner.xcworkspace -scheme Runner -sdk iphoneos -configuration Release build CODE_SIGNING_ALLOWED=NO`
after `flutter build ios --config-only --release`. The CI workflow does exactly that.

### `No release AAB at app/build/outputs/bundle/...`

Gradle did not produce the bundle where the lane looks. Check the Gradle output in the log. For Flutter the bundle is under
`build/app/outputs/bundle/release/`, which the lane finds automatically. If another step built the bundle, set `AAB_PATH` to
its location.

### `Keystore not found at ...`

`ANDROID_KEYSTORE_PATH` points to a file that does not exist. In CI the workflow writes the keystore from
`ANDROID_KEYSTORE_BASE64` during the job. If that step did not run, check that the secret is set and that its base64 decodes
(`base64 --decode` on the value).

### `Could not find a Podfile` or `No Podfile found`

The project has no Podfile. Flutter projects without plugins that need CocoaPods, and native projects without CocoaPods, do
not have one. The CI job runs `pod install` only when a Podfile exists, so this is not an error in the workflow.

## Repository and Xcode

### The Flutter or React Native Xcode project is missing in a clean clone

The `.gitignore` of a repository that contains `*.xcodeproj` excludes Xcode projects. Generated projects must be tracked
explicitly. Remove the rule for your project's `ios/` folder, or force-add `project.pbxproj` and the shared schemes. Do not
commit `xcuserdata/`.

### `Could not automatically select an Xcode project` (CocoaPods)

`pod install` could not find an `.xcodeproj` in `ios/`. Check the project is there and tracked by git.

## Secrets and CI

### `Missing environment variables: ...`

The lane stops before any store call and names the variables it needs. Set the secrets listed in
`.github/workflows/mobile-release.yml`. The [credentials](mobile-credentials.md) page explains each one.

### `ASC_KEY_FILEPATH does not exist: ...`

The `.p8` file was not written. Check the **Write App Store Connect API key** step of the job, and that `ASC_KEY_P8` is
the full contents of the file, including the BEGIN and END lines.

### `Could not find any matching profile` or match fails on CI

`match` runs readonly on CI, so it cannot create missing certificates. Run `bundle exec fastlane match appstore` once from a
trusted machine (not readonly) to create them. Check that `MATCH_GIT_URL` is readable from the runner, and that
`MATCH_PASSWORD` is the passphrase the repository was encrypted with.

### `Keychain` or signing errors on the runner

The iOS lanes call `setup_ci` on CI, which makes a temporary keychain. If the runner's keychain is locked or has no access to the
signing identity, the build fails with a codesign error. Check the job log for the keychain step, and that the runner is a
macOS machine with Xcode.

### `Upload fails with 403` (Google Play)

The service account has no release permission for this app. Grant it release access in Play Console under **Users and
permissions**. A brand-new app may also need its first release uploaded by hand.

### `The bundle is unsigned` or `jar is unsigned`

The release bundle was built without the upload keystore. The lane passes the keystore to Gradle as
`android.injected.signing.*`. Check the four `ANDROID_KEY*` and `ANDROID_KEYSTORE_*` secrets, and the log of the Gradle step.

## Verification

If something fails that is not listed here, run the same steps locally with `kinhin mobile init --dry-run` and the lanes, and
compare with the examples in the repository. The `examples/` folder holds a working project for each framework.
