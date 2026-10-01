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
  also requires the DMG to be signed by the **same Team ID as the running app**, with a Developer
  ID Application certificate (`codesign -R`), and accepted by Gatekeeper (`spctl`: notarized, not
  revoked). A DMG that fails either check is deleted. Only `kinhin-<version>-arm64.dmg` for a
  `vMAJOR.MINOR.PATCH` tag is offered; download and checksum URLs must point at
  `github.com/<repo>/releases/download/…`, redirects may only stay on GitHub hosts, and file names
  must be plain names. Builds without a Developer ID (forks, local builds) can't pin a signer and
  fall back to the checksum alone, with a warning in the log; a build whose own signature can't be
  read refuses updates. Signed builds ignore `KINHIN_UPDATE_REPO`, so it can't redirect a release
  build, and the Team ID pin means it couldn't make one install someone else's binary anyway.

## Update checks

After installing, the menu bar app checks GitHub Releases at most once a day and shows an
**Update available — kinhin x.y.z…** item when a newer `v*` release exists; clicking it downloads
the DMG (via URLSession, so it is never quarantined; it is verified as described above) and opens it for a one-click install. Forks and local (ad-hoc) builds can point it at their own repo with
`KINHIN_UPDATE_REPO=owner/name`; signed release builds ignore that variable.
