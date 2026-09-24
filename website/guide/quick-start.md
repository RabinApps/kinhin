# Quick start

Kinhin turns your Apple Silicon Mac into an autoscaling fleet of ephemeral self-hosted CI
runners. This page gets you from zero to a working fleet.

## Requirements

- Apple Silicon Mac (arm64), macOS 13+
- [Tart](https://tart.run) — macOS runner VMs:
  ```bash
  brew tap openai/tools
  brew trust openai/tools
  brew install openai/tools/tart
  ```
- A GitHub PAT with `repo` scope (or a Gitea access token — see [Forge support](/guide/forges))
- Optional — Linux jobs in [apple/container](https://github.com/apple/container):
  `brew install container && container system start` (macOS jobs always need Tart)
- ~60 GB free disk for the base image plus per-VM scratch

## Install (one line)

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
```

Pinned version, or from a local DMG (air-gapped machines):

```bash
curl -fsSL ... | bash -s -- v0.1.0
bash scripts/install.sh /path/to/kinhin-0.1.0-arm64.dmg
```

The script sha256-verifies the DMG against the release `checksums.txt`, copies **kinhin.app**
to /Applications, and symlinks the `kinhin` CLI into your bin dir. Downloads made with `curl`
carry no quarantine attribute, so the app launches with **no Gatekeeper prompts and no
notarization**.

## First fleet (CLI)

```bash
# 1. Create a starter config
kinhin config init
#    edit ~/Library/Application Support/Kinhin/config.yaml
#    -> set repo: "your-org/your-repo" and the labels jobs will request

# 2. Store a GitHub PAT (repo scope) — it goes in your Keychain, not a file
kinhin auth set

# 3. Check prerequisites and see how many VMs your Mac can host
kinhin doctor

# 4. Prepare the runner base image (once; downloads + provisions a VM, takes a while)
kinhin image prepare

# 5. Go
kinhin start          # foreground, Ctrl-C to stop
# or
kinhin daemon install # headless LaunchAgent, survives reboots
```

Dispatch a workflow whose job matches your labels:

```yaml
jobs:
  build:
    runs-on: [self-hosted, macos, arm64] # must include all configured labels
    steps:
      - run: uname -m # arm64 — you're running on your own Mac
```

Watch the fleet: `kinhin watch` (live) or `kinhin status` (one shot).

## First fleet (menu bar app)

Install with the one-liner above, then launch **kinhin** from Applications. The setup window
walks through the same steps — installing tart, creating the config, storing the token, and
preparing the image — then starts the fleet. The menu bar shows the number of live runner VMs.

::: warning Unsigned app note
The app is not notarized. On first launch, right-click → **Open**, or run
`xattr -cr /Applications/kinhin.app`.
:::
