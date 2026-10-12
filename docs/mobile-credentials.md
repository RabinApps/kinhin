# Mobile release credentials

Every secret the release workflow reads, where to get it, and what each one is for. None of them are stored by kinhin.
Store them as repository secrets (**Settings**, then **Secrets and variables**, then **Actions**). The workflow maps them
into the lanes, and each lane checks for the ones it needs before any store call.

[← Back to mobile releases](mobile-fastlane.md) · [Tutorial](mobile-fastlane-tutorial.md) · [Troubleshooting](mobile-fastlane-troubleshooting.md)

| Secret | Platform | Used for |
| --- | --- | --- |
| `ASC_KEY_ID` | iOS | App Store Connect API key ID |
| `ASC_ISSUER_ID` | iOS | App Store Connect issuer ID |
| `ASC_KEY_P8` | iOS | Contents of the `.p8` key file |
| `MATCH_GIT_URL` | iOS | Git URL of the certificates repository |
| `MATCH_PASSWORD` | iOS | Passphrase that encrypts the certificates repository |
| `APPLE_TEAM_ID` | iOS | Developer Portal team ID |
| `APP_IDENTIFIER` | iOS | Bundle ID, for example `com.example.myapp` |
| `IOS_SCHEME` | iOS | Xcode scheme to build. Empty means the project's default (`Runner` for Flutter). |
| `ANDROID_PACKAGE_NAME` | Android | Application ID, for example `com.example.myapp` |
| `PLAY_SERVICE_ACCOUNT_JSON` | Android | JSON key of the Google Play service account |
| `ANDROID_KEYSTORE_BASE64` | Android | Upload keystore, base64-encoded |
| `ANDROID_KEYSTORE_PASSWORD` | Android | Keystore password |
| `ANDROID_KEY_ALIAS` | Android | Alias of the upload key in the keystore |
| `ANDROID_KEY_PASSWORD` | Android | Password of the upload key |

## App Store Connect API key

The key lets fastlane upload builds without your Apple ID password.

1. In App Store Connect, open **Users and Access**, then **Integrations**, then **App Store Connect API**.
2. If the API has not been enabled for the team, the Account Holder must request access there first.
3. Choose **Generate API Key** (a **Team** key). Give it the **App Manager** role, or **Admin**, which can also upload.
   Team keys apply to every app in the team. Individual keys belong to one user.
4. Download the `.p8` file. Apple offers it **once**: if you lose it, revoke the key and create another.
5. Copy the **Key ID** into `ASC_KEY_ID`, and the **Issuer ID** shown at the top of the page into `ASC_ISSUER_ID`.
6. Store the contents of the `.p8` file as `ASC_KEY_P8`. The workflow writes it to a temporary file during the job and
   deletes it afterwards. On macOS, `pbcopy < AuthKey_XXXX.p8` copies it.

Revoke a key you no longer use. Anyone with the `.p8` and the IDs can act with its role.

## Match: certificates and profiles

`match` keeps signing certificates and provisioning profiles in a git repository, encrypted with `MATCH_PASSWORD`.

1. Create an empty **private** repository for it, for example `my-org/certificates`.
2. Set `MATCH_GIT_URL` to its SSH or HTTPS URL. The CI runner needs read access to it. For a private repository that is
   a deploy key or a token in the URL. A token in a URL is visible to anyone with access to the job logs, so prefer a
   deploy key.
3. Choose `MATCH_PASSWORD`, and keep a copy somewhere safe. Without it the repository cannot be decrypted.
4. Create the certificates once from your own Mac: `bundle exec fastlane match appstore` (not readonly). After that the
   CI job runs `match` readonly and only reads them.

## Apple team and bundle ID

- `APPLE_TEAM_ID` is the 10-character team ID in the Apple Developer account, under **Membership details**.
- `APP_IDENTIFIER` is the bundle ID, which must match the app in App Store Connect. Create the app there first, with the
  same bundle ID.

## Google Play service account

Play uploads use a service account that the Play Developer API trusts.

1. In Google Cloud, create a project, or use an existing one, and enable the **Google Play Android Developer API**.
2. Create a service account, and create a **JSON key** for it. Keep the file private.
3. In Play Console, open **Users and permissions**, invite the service account's email address, and grant it release
   permissions for your app. Upload to the internal track needs the release permission.
4. Store the whole JSON file as `PLAY_SERVICE_ACCOUNT_JSON`.

The first release of a new app is usually uploaded by hand in Play Console, because the API does not always accept the
first upload. Once the app exists and has a release, the lanes can upload.

## Android upload keystore

Google Play App Signing holds the app's signing key. You sign uploads with an upload key, which is the keystore below.

```bash
keytool -genkeypair -v -keystore upload.keystore -alias upload -keyalg RSA -keysize 2048 -validity 10000
```

- `ANDROID_KEY_ALIAS` is the alias you chose (`upload` above).
- `ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_PASSWORD` are the passwords you entered.
- `ANDROID_KEYSTORE_BASE64` is the keystore, base64-encoded: `base64 -i upload.keystore | pbcopy` on macOS.

Back up the keystore and its passwords. If you lose the upload key, Play Console can reset it, but that is a manual
process.

## Checking a secret before a run

A lane names the missing variables and stops before any store call. For example, `fastlane ios beta` without
`ASC_KEY_ID` fails with `Missing environment variables: ASC_KEY_ID, ...`. A variable can be set but still wrong. Those
show up later, as an authentication or signing error, which the [troubleshooting](mobile-fastlane-troubleshooting.md)
page covers.
