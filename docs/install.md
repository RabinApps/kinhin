# Installing and updating kinhin

The install script in detail, and update checks.

[← Back to README](../README.md)

## Install script

Latest release:

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

Pinned version, or from a local DMG (air-gapped machines):

```bash
curl -fsSL .../install.sh | bash -s -- v0.1.0
bash scripts/install.sh /path/to/kinhin-0.1.0-arm64.dmg
```

The script sha256-verifies the DMG against the release `checksums.txt`, copies **kinhin.app** to
/Applications, and symlinks the `kinhin` CLI into your bin dir — the first writable of
/opt/homebrew/bin, /usr/local/bin, and ~/.local/bin. Release artifacts are
Developer ID signed and notarized, so the app launches with **no Gatekeeper prompts** — the
Open-Anyway dance only applies to old releases or locally built copies (clear it with
`xattr -cr /Applications/kinhin.app`). Remove everything with `bash scripts/install.sh --uninstall`
(config and your Keychain PAT are kept).

## How updates and installs are verified

- **Install script:** it refuses a download that has no `checksums.txt`, matches the DMG's file name
  exactly, fetches over https only (TLS 1.2+), checks the app's code signature before copying it,
  and never strips the quarantine attribute. A local DMG is checked against `DMG.sha256` when one
  sits next to it.
- **Update check:** a checksum only proves the file matches its release, so a Developer ID build
  also requires the DMG to be signed by the **same Team ID as the running app** (`codesign -R`
  against that Team ID); a DMG that fails is deleted. Download and checksum URLs must point at
  `github.com/<repo>/releases/download/…`, and file names must be plain names. Builds without a
  Developer ID (forks, local builds) can't pin a signer and fall back to the checksum alone, with
  a warning in the log. Because of the pin, `KINHIN_UPDATE_REPO` can't make a release build install
  someone else's binary.

## Update checks

After installing, the menu bar app checks GitHub Releases at most once a day and shows an
**Update available — kinhin x.y.z…** item when a newer `v*` release exists; clicking it downloads
the DMG (via URLSession, so it is never quarantined; it is verified as described above) and opens it for a one-click install. Point it
at your fork with `KINHIN_UPDATE_REPO=RabinApps/kinhin` if needed.
