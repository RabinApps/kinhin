---
name: kinhin-install
description: Install kinhin and its prerequisites (Tart) on an Apple Silicon Mac, locally or on a rented or remote Mac, and run the first-time setup sequence. Use when the user wants to install, set up or bootstrap kinhin, or get a new Mac serving CI jobs.
---

# Install kinhin

kinhin turns an Apple Silicon Mac into an autoscaling pool of ephemeral self-hosted CI runners: one fresh VM or
container per job, deleted afterwards. This skill covers install and first run.

**Beta status (tell the user):** GitHub, Gitea, Forgejo and GitLab CE are supported. Gitea, Forgejo and GitLab CE have run real jobs on
every runtime; GitHub on Tart macOS VMs and apple/container. Buildkite, Azure DevOps and Bitbucket are planned. Findings are welcome as GitHub issues ("Forge report").

## Requirements

- Apple Silicon and macOS 15 or newer (Intel is unsupported).
- About 60 GB free disk and at least 16 GB RAM. An 8 GB Mac should use Linux containers only.
- A forge token (see the `kinhin-configure` skill).
- Tart, for macOS VMs.

Check the machine first: `uname -m` must print `arm64`, and `sw_vers -productVersion` must be 15 or newer.

## 1. Install Tart

```bash
kinhin setup repair tart
```

(The `kinhin` CLI comes from step 2, so install kinhin first if the command is missing.) If `kinhin doctor` later
reports `tart: INSTALLED BUT KILLED ON LAUNCH`, the bottle is un-notarized; `kinhin doctor` prints the exact rollback
commands, and the manual brew equivalents are in `docs/install.md#installing-tart`.

## 2. Install kinhin

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

- Pin a version: `... | bash -s -- v0.1.0` (use a real release tag).
- Air-gapped: download `scripts/install.sh` and the DMG, then `bash install.sh /path/to/kinhin-<version>-arm64.dmg`.
- The installer verifies the DMG against the release `checksums.txt` and the code signature, copies `kinhin.app` to
  `/Applications`, and symlinks the `kinhin` CLI into the first writable of `/opt/homebrew/bin`, `/usr/local/bin`,
  `~/.local/bin`. Overrides: `REPO`, `INSTALL_DIR`, `BIN_DIR`.
- Old or locally built copies may need `xattr -cr /Applications/kinhin.app`. Official releases are notarized.

## 3. First-run sequence

Run these in order, stopping to fix any failure before the next step:

1. `kinhin config init` writes a commented starter config to
   `~/Library/Application Support/Kinhin/config.yaml`.
2. Edit `accounts:` and `labels` (use the `kinhin-configure` skill), then `kinhin config validate`.
3. `kinhin auth set` stores the token in the Keychain. Never put tokens in the config or on the command line if you
   can avoid it. `--token-stdin` reads it from stdin; `--token X` still works but prints a warning.
4. `kinhin doctor` checks Tart, disk, the token and the capacity cap.
5. `kinhin image prepare` builds the base image. It runs once, is slow and uses roughly 40 to 60 GB.
6. `kinhin start` runs in the foreground. `kinhin daemon install` installs a LaunchAgent that survives reboots.
7. Trigger a workflow with `runs-on: [self-hosted, macos, arm64]` and watch with `kinhin watch` or `kinhin status`.

## Second Mac with the same setup

On the Mac that already works: `kinhin config export kinhin-config.yaml`. On the new Mac, after installing:
`kinhin config import kinhin-config.yaml`, then store each token it lists with `kinhin auth set --account NAME`, then
`kinhin setup status` for the images to prepare. Tokens and images are never copied. Over SSH in one step:
`kinhin config export | ssh other-mac kinhin config import - --yes` (ask before `--yes` replaces an existing config).

## Rented or remote Mac

From your own machine:

```bash
ssh admin@host 'bash -s' < scripts/bootstrap-rented-mac.sh
```

The script is idempotent: it checks arm64 and macOS 15+, installs Tart and kinhin if missing, runs
`kinhin config init` if there is no config, and prints next steps. It never touches a token.

Then, on the Mac:

- Run `security unlock-keychain ~/Library/Keychains/login.keychain-db` in the SSH session, or the Keychain stays locked.
- Enable automatic login and keep FileVault off, because the LaunchAgent needs a GUI session.
- Run `kinhin daemon install` from a VNC or Screen Sharing session.
- Use one customer per Mac. Never pass tokens as arguments or environment variables.

## Update and uninstall

- Update: re-run the install command (the CLI has no update command), then re-run `kinhin image prepare`.
- Uninstall, in this order: stop the fleet, `kinhin cleanup --all --yes`, `kinhin daemon uninstall`, then
  `bash install.sh --uninstall`. The config and Keychain token are kept. Delete the config directory and the Keychain
  entries by hand if the user wants them gone.

## More

- [Install guide](https://github.com/RabinApps/kinhin/blob/main/docs/install.md)
- [Rented Mac guide](https://github.com/RabinApps/kinhin/blob/main/docs/rented-mac.md)
- [Hardware sizing](https://github.com/RabinApps/kinhin/blob/main/docs/hardware.md)
- If a command here fails or differs, trust `kinhin help` and `kinhin <command> --help` over this page.
