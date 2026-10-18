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

## Changelog between releases

Every user-visible change adds a bullet under `## Unreleased` in `CHANGELOG.md`, in the same PR as the change. Group
bullets under **Added**, **Changed**, **Fixed** or **Removed**. `scripts/check.sh` and CI run `scripts/changelog.sh check`,
which fails when the headings are malformed (a missing or misplaced `## Unreleased`, or a version heading that is not
`## v<version>`). It does not require entries, so an empty Unreleased section is fine between releases.

At release time, `scripts/changelog.sh promote <version>` renames `## Unreleased` to `## v<version>` and leaves a fresh
empty Unreleased section above it. It refuses an empty section and a version that already has a heading. The release
notes are that version's section, so they come from the bullets written during development.

## The two paths

**Local rehearsal** — prove the build, the signing and the installer stamping before a tag exists:

```bash
# 1. Promote the changelog and bump the version, in one commit
scripts/changelog.sh promote <version>   # renames "## Unreleased" to "## v<version>", starts a fresh Unreleased
#    Sources/KinhinKit/Core/Version.swift   current = "<version>"
scripts/docs-sync.sh                     # rewrites the README, roadmap and home banners from Version.swift
#    git add CHANGELOG.md Sources/KinhinKit/Core/Version.swift README.md docs/beta-roadmap.md website/.vitepress/theme/HomeBanners.vue
#    git commit -m "Release v<version>"

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
the four files to a GitHub Release, with the version's CHANGELOG section as its notes. The workflow
runs in the protected `release` environment, so secrets are only reachable after a reviewer approves.
It needs a runner labelled `kinhin-xcode` (a Tart pool on a kinhin fleet).

**Local publish** — when no `kinhin-xcode` runner is available, publish the verified local `dist/`
instead. `gh` creates the tag on GitHub together with the release, so when the tag's
`release.yml` run starts, its `existing` job finds the release and skips the rebuild. The commit you
built must already be pushed.

```bash
awk -v h="## v<version>" '$0 == h {f=1; next} /^## /{f=0} f' CHANGELOG.md > dist/release-notes.md
gh release create v<version> --target "$(git rev-parse HEAD)" --latest --title "v<version>" \
  --notes-file dist/release-notes.md \
  dist/kinhin-<version>-arm64.dmg dist/kinhin-cli-<version>-arm64.zip dist/install.sh dist/checksums.txt
git fetch --tags
```

## The scripts

| Script                        | Role                                                                                                  |
| ----------------------------- | ----------------------------------------------------------------------------------------------------- |
| `scripts/release.sh`          | The orchestrator: preflight → gates → build → artifacts → summary                                      |
| `scripts/build-app.sh`        | Assembles `dist/kinhin.app`: builds both products, hash-verifies every copied binary, generates App Intents metadata, signs inside-out (nested CLI first) |
| `scripts/make-dmg.sh`         | Wraps `build-app.sh`, packs the DMG with an `/Applications` shortcut, signs it, calls `notarize.sh`     |
| `scripts/notarize.sh`         | Submits to Apple, waits for the verdict, prints the notary log on rejection, staples DMGs — as `submit` / `wait` / `staple` / `status` subcommands so an interrupted run resumes (see below) |
| `scripts/release-artifacts.sh`| CLI zip → Gatekeeper + in-bundle version verification → Team-ID-stamped `install.sh` → `checksums.txt` |

`release-artifacts.sh` pins `checksums.txt` to the version's own files: `dist/` is a workbench, and a
wildcard would silently checksum whatever older artifacts happen to be lying next to the new ones.

## Apple's queue can take hours

Notarization is not a local step: the upload returns in seconds, then Apple's queue runs server-side.
A first submission, or a busy day at Apple, can sit at `In Progress` for hours — a recurring, documented
service problem, not a sign that anything is wrong with the build.

So `scripts/notarize.sh` never holds the verdict in memory. The submission id is written to a sidecar
next to the artifact the moment the upload returns:

```
dist/kinhin-0.0.1-beta-1-arm64.dmg.notary   # sha256=… id=… submittedAt=…
```

Whatever kills the waiting process — a tool-call timeout, a CI job limit, Ctrl-C — the submission
stays alive on Apple's side and the id survives. Pick it up whenever:

```bash
scripts/notarize.sh status dist/kinhin-<v>-arm64.dmg   # id + live status
scripts/notarize.sh wait   dist/kinhin-<v>-arm64.dmg   # poll until it settles, then staple
scripts/notarize.sh staple dist/kinhin-<v>-arm64.dmg   # staple now, if it is already Accepted

NOTARY_KEYCHAIN_PROFILE=kinhin ./scripts/release-artifacts.sh <v>   # finish the rest of the run
```

The four subcommands are also how the default form stays honest:

- `notarize.sh <file>` (= submit → wait → staple) **resumes** a recorded submission instead of
  uploading the same bytes again.
- The sidecar stores the artifact's `sha256`, so a rebuilt DMG or zip can never be stapled against
  another build's ticket — it fails with instructions instead.
- `NOTARY_WAIT_SECONDS` bounds the wait (unset = as long as Apple takes). On expiry the script exits
  **75** — distinct from a rejection — and prints the resume commands; nothing was lost.
- `release.sh` prints the same resume hint if it dies with a submission in flight.

A fresh `release.sh` run clears stale sidecars with the rest of `dist/`, so a new release never
resumes an old submission.

## Update signing key (one time, then keep it)

The updater only installs archives signed with one EdDSA key. The public half is baked into every build; the private
half signs each release. Losing the private key strands every installed copy, so keep a backup in a password manager.

1. Fetch the pinned Sparkle 2.10.0 tools and check the archive. Use the same version the release workflow pins (its
   `SPARKLE_VERSION` and `SPARKLE_SHA256` in `.github/workflows/release.yml`):

   ```bash
   curl -fsSL -o Sparkle-2.10.0.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
   ```

   ```bash
   echo "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  Sparkle-2.10.0.tar.xz" | shasum -a 256 -c -
   ```

   ```bash
   mkdir -p ~/sparkle && tar -xJf Sparkle-2.10.0.tar.xz -C ~/sparkle
   ```

2. Generate the key pair. This stores the private key in your login Keychain and prints the **public key**. The public
   key is not secret; copy it for step 5.

   ```bash
   ~/sparkle/bin/generate_keys
   ```

3. Export the private key to a file, which is the value for the CI secret. Keep a backup of it in your password
   manager: a lost private key strands every installed copy.

   ```bash
   ~/sparkle/bin/generate_keys -x ~/sparkle/sparkle_private_key.txt
   ```

4. Store the private key as the secret `SPARKLE_ED_PRIVATE_KEY` in the **`release` environment**, not at repository
   level. The release job runs in that environment, which holds the signing secrets and its required reviewers, and
   environment-scoped secrets are only visible to it.

   ```bash
   cat ~/sparkle/sparkle_private_key.txt | gh secret set SPARKLE_ED_PRIVATE_KEY --env release --repo RabinApps/kinhin
   ```

5. Store the public key as the variable `KINHIN_SPARKLE_PUBLIC_KEY` in the same environment. Replace PUBLIC_KEY
   with the value from step 2:

   ```bash
   gh variable set KINHIN_SPARKLE_PUBLIC_KEY --env release --repo RabinApps/kinhin --body "PUBLIC_KEY"
   ```

   The web UI does the same: Settings → Environments → `release`, with the secret under Secrets and the variable under
   Variables.

6. Delete the exported file once it is stored and backed up:

   ```bash
   rm ~/sparkle/sparkle_private_key.txt
   ```

A signed build fails without the variable, and a release fails without the secret; that is deliberate, since a build
without the public key would ship an updater that can't install anything.

A local rehearsal signs the same way, with the key in the environment and `SPARKLE_TOOLS` pointing at the unpacked
tools: `KINHIN_SPARKLE_PUBLIC_KEY=… SPARKLE_ED_PRIVATE_KEY="$(cat key.txt)" SPARKLE_TOOLS=~/sparkle scripts/release.sh
VERSION`. Without the secret the run writes no appcast.

## After the release

- **Required:** add the tag to `website/versions.json` so the docs site snapshots it (see
  [CONTRIBUTING.md](../CONTRIBUTING.md#docs-versions)). Do it once the tag exists on GitHub.
- The README banner, the roadmap's first sentence and the home banner title follow `Version.swift`: `scripts/docs-sync.sh --check`
  (in `scripts/check.sh`, and in `scripts/release.sh`'s preflight) fails if they name another version. The beta-N links and the
  "(current)" roadmap heading are still edited by hand in the release commit.
- The in-app updater (Sparkle) checks its appcast at most once a day. It installs only archives signed with the EdDSA
  key in `SUPublicEDKey`, and a Developer ID build also needs a Gatekeeper-accepted signature ([Install](install.md)).
  The release uploads `appcast.xml` next to the DMG; the docs deploy (which runs after a successful Release) copies
  it to <https://kinhin.dev/appcast.xml>, where the app reads it.
- A beta (`-beta-N`) is published as the latest release, not a prerelease: GitHub's
  `releases/latest`, which the install URL and `install.sh` resolve, never returns a prerelease.

## Verifying a shipped artifact

```bash
xcrun stapler validate dist/kinhin-<v>-arm64.dmg
spctl -a -vv -t open --context context:primary-signature dist/kinhin-<v>-arm64.dmg
shasum -a 256 -c <(grep 'kinhin-<v>-arm64.dmg' dist/checksums.txt)
```

`scripts/release.sh` runs these for you; they are what `install.sh` and the updater check on the
user's machine.
