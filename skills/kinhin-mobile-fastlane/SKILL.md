---
name: kinhin-mobile-fastlane
description: Set up fastlane store releases (TestFlight, App Store, Google Play) for iOS, Android, Flutter, React Native or Expo projects, and run them from a kinhin runner - `kinhin mobile init` scaffolding, lanes, App Store Connect API keys, match, Play service accounts, the mobile-release workflow, and Expo EAS. Use when the user wants to ship a mobile app, automate TestFlight or Play uploads, or fix a failing fastlane lane.
---

# Mobile releases with fastlane

The full reference is `docs/mobile-fastlane.md` in the kinhin repo. Read it for secrets, lanes and framework notes.
Use this skill to pick the right path and run the steps.

## Pick the path

1. **Expo** (`"expo"` in `package.json`): use EAS Build and EAS Submit by default. `kinhin mobile init` writes only
   `eas.json` for Expo. For fastlane, run `npx expo prebuild` first, then scaffold as React Native.
2. **Flutter, React Native (bare), native iOS or Android**: scaffold with fastlane.

## Scaffold

Run this from any machine with kinhin installed. It never overwrites existing files unless `--force` is given:

```bash
kinhin mobile init --dry-run /path/to/app
kinhin mobile init /path/to/app
```

Override detection with `--framework ios|android|flutter|react-native|expo|native` when the layout is unusual.

Then in the project:

```bash
bundle install
# From the folder that holds fastlane/ (ios/ or android/ for Flutter and React Native)
cd ios && bundle exec fastlane lanes
```

## Before the first upload

- Create an App Store Connect **team** API key. The `.p8` downloads once only. Store it as the `ASC_KEY_P8` secret.
- Set up `match` once, from a trusted machine: `MATCH_READONLY=false bundle exec fastlane match appstore`. Keep `MATCH_PASSWORD` in secrets.
- Create a Play service account, invite it in Play Console with release permissions, and store its JSON as
  `PLAY_SERVICE_ACCOUNT_JSON`.
- Create the upload keystore and store it base64-encoded as `ANDROID_KEYSTORE_BASE64`.

The workflow asks for `runs-on: [self-hosted, kinhin-xcode]`. Change the label if the pool uses another name.

## Run

Trigger the `mobile-release` workflow manually with `lane: beta` first. Use `release` only after a `beta` build has
processed. Confirm the build appears in TestFlight or the Play internal track before going further.

## Troubleshooting

- **`match` fails on CI with no matching profile**: the template runs `match` readonly, so CI never creates certificates.
  Run `MATCH_READONLY=false bundle exec fastlane match appstore` once from a trusted machine to create them, then re-run the workflow.
- **`upload_to_play_store` fails with 403**: the service account lacks release permissions for this app in Play Console.
- **Flutter `ipa` build fails**: it needs a distribution certificate, not a development one.
- **Expo local build ignores `fastlane` in `eas.json`**: this is expected. Local builds ignore it.
- **`Missing environment variables: ...`**: the lane checks its secrets first and stops before any store call. Set the listed names in CI.
- **`No release AAB at ...`**: Gradle did not produce the bundle. Check `AAB_PATH` if another step builds it.
- **`bundler could not find compatible versions for gem "ruby"`**: fastlane needs Ruby 3.2+ (the `~> 2.240` pin resolves to 2.241). The macOS system Ruby is 2.6. Use Ruby 3.3 locally, and the workflow's `ruby/setup-ruby` step on CI.
- Gradle prints secrets: the template sets `print_command: false`. Keep it that way.
