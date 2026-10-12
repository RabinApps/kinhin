# Tutorial: your first TestFlight or Play internal build

This walks through a first release from a clean start: scaffold the project, set up the credentials once, run a `beta`
lane by hand, then run it from CI. It takes about an hour the first time, most of it waiting on Apple and Google.

[← Back to mobile releases](mobile-fastlane.md) · [Credentials](mobile-credentials.md) · [Troubleshooting](mobile-fastlane-troubleshooting.md)

## What you need

- A Mac with kinhin installed (`kinhin` on your PATH), Xcode, and Ruby 3.2 or newer. The macOS system Ruby (2.6) is too
  old. Install Ruby 3.3 with Homebrew (`brew install ruby@3.3`) or rbenv.
- For iOS: an Apple Developer Program membership. The **Account Holder** requests API access, and an **Account Holder** or **Admin** creates the team key.
- For Android: a Google Play Console developer account, and a Google Cloud project you can create a service account in.
- A repository for the app, on GitHub, Gitea, Forgejo or GitLab, with a runner that has the `kinhin-xcode` label.

Your app already builds locally. Check that first: `flutter build`, `npx react-native run-ios`, or Xcode and Android
Studio for native apps.

## 1. Scaffold the project

From anywhere, point `kinhin mobile init` at the project folder:

```bash
kinhin mobile init --dry-run ~/code/my-app   # see what would be written
kinhin mobile init ~/code/my-app
```

It detects the framework. Flutter and React Native get fastlane in `ios/` and `android/`; a native app gets it at its root;
an Expo app gets `eas.json` only, unless you run `npx expo prebuild` first (see the [reference](mobile-fastlane.md#expo)).
It writes a `Gemfile` that pins fastlane, the lanes, and `.github/workflows/mobile-release.yml`. Existing files are kept, so
you can run it again safely.

Install the gems and list the lanes, from the folder that holds `fastlane/`:

```bash
cd ~/code/my-app/ios        # Flutter and React Native; a native app stays at its root
bundle install
bundle exec fastlane lanes
```

You should see `ios beta` and `ios release` (and `android beta` and `android build` in the Android folder). Commit the
scaffolded files before going on.

## 2. Create the App Store Connect API key (iOS)

App Store Connect uses an API key instead of your Apple ID password. In App Store Connect, open **Users and Access**,
then **Integrations**, then **App Store Connect API**, and request access if you have not yet (only the Account Holder can).
Create a **Team** key, and download the `.p8` file. Apple's page says API keys "can only be downloaded once". Apple's page does not list which roles can upload builds, so confirm the key works with a first upload.

Note the **Key ID** and the **Issuer ID**. You will store the `.p8` contents as a secret in step 4. The details are in
[credentials](mobile-credentials.md#app-store-connect-api-key).

## 3. Set up code signing with match (iOS)

`match` keeps your signing certificates and profiles in a private, encrypted git repository, so CI can use them without
you copying certificates by hand.

1. Create an empty private repository for certificates, for example `my-org/certificates`.
2. Choose a passphrase for it and keep it safe. It becomes `MATCH_PASSWORD`.
3. Run `match` once from your own Mac, not on CI, to create the certificates and profiles:

```bash
cd ~/code/my-app/ios
MATCH_GIT_URL=git@github.com:my-org/certificates.git MATCH_PASSWORD='your passphrase' \
  APP_IDENTIFIER=com.example.myapp APPLE_TEAM_ID=ABCDE12345 \
  bundle exec fastlane match appstore
```

`match` asks for the passphrase, unless `MATCH_PASSWORD` is set, which avoids the prompt. Afterwards the repository holds the encrypted certificates. CI runs `match`
readonly, so it never creates or changes them.

## 4. Add the secrets

In your repository, open **Settings**, then **Secrets and variables**, then **Actions**, and add the secrets listed in
the header of `.github/workflows/mobile-release.yml`. For iOS you need `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`,
`MATCH_GIT_URL`, `MATCH_PASSWORD`, `APPLE_TEAM_ID`, `APP_IDENTIFIER` and `IOS_SCHEME`. Each one is explained in
[credentials](mobile-credentials.md).

`IOS_SCHEME` is the Xcode scheme to build. For Flutter it is `Runner`, which is the default when the secret is empty.

## 5. Set up Android (optional, same steps)

1. Create an upload keystore once, and keep the file and its passwords somewhere safe:

```bash
keytool -genkeypair -v -keystore upload.keystore -alias upload -keyalg RSA -keysize 2048 -validity 10000
```

2. Store it base64-encoded, as `ANDROID_KEYSTORE_BASE64`. On macOS: `base64 -i upload.keystore | pbcopy`.
3. Create a Google Cloud service account, enable the Google Play Developer API for it, and invite it in Play Console with
   **Release apps to testing tracks** permission for your app. Store its JSON key as `PLAY_SERVICE_ACCOUNT_JSON`.

The full steps are in [credentials](mobile-credentials.md#google-play-service-account).

The app must exist in Play Console before the first upload. Create it there, with the package name you put in
`ANDROID_PACKAGE_NAME`. The first upload must be made by hand in Play Console, as the fastlane supply docs say. The lanes can take over after that.

## 6. Run a beta locally first

Before CI, run the lanes on your Mac with the same secrets exported. Keep them out of shell history:

```bash
cd ~/code/my-app/ios
bundle exec fastlane beta
```

A successful run uploads the build to TestFlight. Apple then processes it for a few minutes before it appears there.
Android works the same way, from the `android` folder: `bundle exec fastlane android beta` uploads to the internal track.
If you only want to check that the Android bundle builds and is signed, run `bundle exec fastlane android build`, which
does not upload.

## 7. Run it from CI

Open **Actions**, choose **mobile-release**, and choose **Run workflow**. Pick `beta` for the lane, and run it.

The job installs Ruby, and for Flutter and React Native the framework tools first, then runs the lane. If it fails, the
first error is in the log of the failing step. The [troubleshooting](mobile-fastlane-troubleshooting.md) page lists the
failures we have seen, with what to do about each.

Use `release` only after a `beta` build has finished processing and you have checked it in TestFlight. The `release`
lane uploads the build to App Store Connect without submitting it for review.

## Where to go next

- The [reference](mobile-fastlane.md) covers each framework, the monorepo layout and the Expo route.
- Add a second lane for production, or wire the `release` lane to a tag, once beta is working for you.
