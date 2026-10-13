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

## Installing Tart

Tart runs the macOS runner VMs (and optional Linux VMs). The app's setup window installs it for you; from the terminal
the same installer is one command:

```bash
kinhin setup repair tart      # skipped if tart is already on your PATH
```

`kinhin doctor` shows the tart state. When it reports `tart: NOT FOUND` or `tart: INSTALLED BUT KILLED ON LAUNCH`, it
prints the exact repair commands for that state, and the app's setup checklist offers them as one-click fixes. Use
those rather than typing brew commands from memory; this section is the only place the manual commands are documented.

These are the manual equivalents, for machines where `kinhin` is not installed yet or Homebrew must be driven by hand:

```bash
# Install (what `kinhin setup repair tart` runs)
brew tap openai/tools
brew trust openai/tools
brew install openai/tools/tart

# If `kinhin doctor` reports "INSTALLED BUT KILLED ON LAUNCH": the OpenAI-tap bottle is un-notarized
# (openai/homebrew-tools#27) and Gatekeeper kills it. Roll back to a notarized build:
brew uninstall openai/tools/tart openai/tools/softnet
brew tap openai/cli
brew trust openai/cli
brew install openai/cli/tart
```

Re-run `kinhin doctor` afterwards; it offers to move back to the OpenAI tap once a fixed bottle ships. The commands
`doctor` prints are authoritative if they differ from this page.

## Installing a Linux runtime

Linux jobs are optional. Tart Linux VMs need nothing beyond Tart. For containers, use **apple/container** first;
choose Docker only if you already run a Docker provider. The [runtime comparison](runtimes.md#choosing-a-linux-runtime)
explains the trade-offs.

### apple/container (recommended)

```bash
kinhin setup repair container      # installs the container CLI and starts its service
```

These are the manual equivalents:

```bash
brew install container
container system start --enable-kernel-install
```

`--enable-kernel-install` installs the default Linux kernel. Without it, `container system start` stops to ask a
question, and every `container run` then fails with "default kernel not configured". Then bake the image with
`kinhin image prepare --container`.

### Docker

`kinhin setup repair docker` installs Docker Desktop by default. Pick another provider with
`--method orbstack` or `--method colima`.

```bash
brew install --cask docker-desktop     # --method desktop (Docker Desktop: open it once after installing)
brew install --cask orbstack           # --method orbstack (OrbStack: open it once after installing)
brew install colima docker && colima start   # --method colima (command line only, no app)
```

Docker Desktop needs macOS 15 or newer and at least 4 GB of RAM. Then bake the image with
`kinhin image prepare --docker`. kinhin does not configure or start your Docker provider; it only runs containers in it.

Both are also what `kinhin video build` uses to build [videos of your own product](videos-for-your-project.md); the first build pulls
a video image of about a gigabyte.

## How updates and installs are verified

- **Install script:** it refuses a download without `checksums.txt`, fetches over https only, and never strips the quarantine attribute. The copy attached to a release is stamped with the Developer ID Team ID of the shipped app, so it refuses an app that is not signed by that team or not accepted by Gatekeeper. A copy run from a checkout or a fork has no Team ID and can only verify that the signature is valid. A local DMG is checked against `DMG.sha256` when one sits next to it.
- **Update check:** besides the checksum, a Developer ID build requires the DMG to be signed by the **same Team ID as the running app** and accepted by Gatekeeper (notarized, not revoked). A DMG that fails either check is deleted. Downloads must come from the project's GitHub releases. Builds without a Developer ID (forks, local builds) fall back to the checksum alone, with a warning in the log.

## Full uninstall

```bash
kinhin cleanup --all               # VMs, images, caches
kinhin daemon uninstall            # the LaunchAgent
bash scripts/install.sh --uninstall   # the app and the CLI
```

`--uninstall` keeps your config and the Keychain PAT. To remove those too, delete the kinhin config directory
and the kinhin entries in Keychain Access.

## Update checks

After installing, the menu bar app checks GitHub Releases at most once a day and shows an
**Update available — kinhin x.y.z…** item when a newer `v*` release exists (beta builds also see `-beta-N` releases); clicking it downloads
the DMG (via URLSession, so it is never quarantined; it is verified as described above) and opens it for a one-click install. Forks and local (ad-hoc) builds can point it at their own repo with
`KINHIN_UPDATE_REPO=owner/name`; signed release builds ignore that variable.
