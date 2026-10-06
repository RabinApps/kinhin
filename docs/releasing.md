# Cutting a release

How a maintainer builds, signs, notarizes and publishes a kinhin release — locally as a rehearsal,
then from a tag for real.

[← Back to README](../README.md)

Contributor conventions are in [CONTRIBUTING.md](../CONTRIBUTING.md); what CI runs is in
[Architecture](architecture.md#ci).

## What a release produces

Four files in `dist/`, all version-pinned to `MAJOR.MINOR.PATCH` (plus an optional `-beta-N` suffix):

| File                            | What it is                                                                                     |
| ------------------------------- | ---------------------------------------------------------------------------------------------- |
| `kinhin-<v>-arm64.dmg`          | The app: `kinhin.app` (bundle executable + `Resources/bin/kinhin` CLI), Developer ID signed, notarized, stapled, Gatekeeper-verified |
| `kinhin-cli-<v>-arm64.zip`      | The CLI alone, Developer ID signed and notarized (zips cannot be stapled)                       |
| `install.sh`                    | The install script, stamped with the Team ID of the app it installs, so a tampered app is refused |
| `checksums.txt`                 | sha256 of those three files — what `install.sh` and the in-app updater verify against           |

The version comes from exactly one place: `Sources/KinhinKit/Core/Version.swift`. Release CI stamps
that file from the tag; nothing else defines the version.

## Prerequisites

- **Full Xcode** selected, not the Command Line Tools — `xcode-select -p` must print
  `/Applications/Xcode.app/Contents/Developer` (`swift test` needs XCTest, which ships with Xcode).
- **A Developer ID Application certificate** in your keychain. `CODESIGN_IDENTITY` overrides;
  otherwise the first one found is used. A release is never ad-hoc signed — an ad-hoc build cannot
  be notarized and Gatekeeper refuses it.
- **Notarization credentials**, one of the two forms:

  ```bash
  # Preferred: a stored notarytool profile. Nothing on disk, nothing in the environment.
  xcrun notarytool store-credentials kinhin \
    --key AuthKey_XXXX.p8 --key-id <key-id> --issuer <issuer-id>

  # Or the App Store Connect API key, all three exported:
  export NOTARY_KEY_PATH=~/keys/AuthKey_XXXX.p8
  export NOTARY_KEY_ID=<key-id>
  export NOTARY_ISSUER_ID=<issuer-id>
  ```

## The two paths

**Local rehearsal** — prove the build, the signing and the installer stamping before a tag exists:

```bash
# 1. Bump the version and the notes, in one commit
#    Sources/KinhinKit/Core/Version.swift   current = "<version>"
#    CHANGELOG.md                           a "## v<version>" heading

# 2. Everything CI runs must be green
scripts/check.sh

# 3. Build, sign, notarize, verify, package
scripts/release.sh <version>
```

`scripts/release.sh` refuses to run on a dirty tree, on a version that disagrees with `Version.swift`,
without the CHANGELOG heading, without a Developer ID identity, or without notarization credentials.
It **never commits, tags or pushes** — its last screen prints the tag commands for you to run.

Flags: `--skip-checks` skips `scripts/check.sh` (iteration only, never ship this way), `--allow-dirty`
runs on an uncommitted tree (warns), `--no-notarize` skips notarization and every check that depends
on it — a smoke run whose output must never be published.

**Tag publish** — the real release:

```bash
git tag v<version>
git push origin v<version>
```

The tag triggers `.github/workflows/release.yml`, which runs the tests, stamps `Version.swift` from
the tag, requires the signing secrets, rebuilds, and runs **the same `scripts/release-artifacts.sh`**
your local run executed — so a checkout release and a tag publish cannot drift apart. It then uploads
the four files to a GitHub Release. The workflow runs in the protected `release` environment, so
secrets are only reachable after a reviewer approves.

## The scripts

| Script                        | Role                                                                                                  |
| ----------------------------- | ----------------------------------------------------------------------------------------------------- |
| `scripts/release.sh`          | The orchestrator: preflight → gates → build → artifacts → summary                                      |
| `scripts/build-app.sh`        | Assembles `dist/kinhin.app`: builds both products, hash-verifies every copied binary, generates App Intents metadata, signs inside-out (nested CLI first) |
| `scripts/make-dmg.sh`         | Wraps `build-app.sh`, packs the DMG with an `/Applications` shortcut, signs it, calls `notarize.sh`     |
| `scripts/notarize.sh`         | Submits to Apple, waits for the verdict, prints the notary log on rejection, staples DMGs               |
| `scripts/release-artifacts.sh`| CLI zip → Gatekeeper + in-bundle version verification → Team-ID-stamped `install.sh` → `checksums.txt` |

`release-artifacts.sh` pins `checksums.txt` to the version's own files: `dist/` is a workbench, and a
wildcard would silently checksum whatever older artifacts happen to be lying next to the new ones.

## After the release

- Add the tag to `website/versions.json` so the docs site snapshots it (see
  [CONTRIBUTING.md](../CONTRIBUTING.md#docs-versions)).
- The in-app updater checks GitHub Releases at most once a day; a Developer ID build only accepts a
  DMG signed by **its own Team ID** and accepted by Gatekeeper ([Install](install.md)).
- A pre-release (`-beta-N`) is published as a prerelease; beta builds see those too.

## Verifying a shipped artifact

```bash
xcrun stapler validate dist/kinhin-<v>-arm64.dmg
spctl -a -vv -t open --context context:primary-signature dist/kinhin-<v>-arm64.dmg
shasum -a 256 -c <(grep 'kinhin-<v>-arm64.dmg' dist/checksums.txt)
```

`scripts/release.sh` runs these for you; they are what `install.sh` and the updater check on the
user's machine.
