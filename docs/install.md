# Installing and updating kinhin

The install script in detail, update checks, and optional Homebrew distribution.

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

## Update checks

After installing, the menu bar app checks GitHub Releases at most once a day and shows an
**Update available — kinhin x.y.z…** item when a newer `v*` release exists; clicking it downloads
the DMG (via URLSession, so it is never quarantined) and opens it for a one-click install. Point it
at your fork with `KINHIN_UPDATE_REPO=RabinApps/kinhin` if needed.

## Homebrew

A personal tap is _not_ required — the one-line install above is the intended path. If you prefer
`brew` on your machines, this repo ships tap templates in `packaging/homebrew-tap/`:

1. Create a repo named `homebrew-tap` under your account.
2. Copy `Casks/kinhin.rb` and `Formula/kinhin.rb` into it, replacing `RabinApps`
   with your GitHub handle.
3. After each release (tag a `v*` and CI publishes the DMG, CLI zip, and `checksums.txt` to
   Releases), update the version and the sha256 values in your tap from that `checksums.txt`.
4. Users install with:

```bash
brew tap RabinApps/tap
brew install --cask kinhin    # menu bar app
brew install kinhin           # CLI
```
