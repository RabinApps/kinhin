# Quick start

Kinhin turns your Apple Silicon Mac into an autoscaling fleet of ephemeral self-hosted CI
runners. This page gets you from zero to a working fleet. New here? Read [why kinhin exists](/guide/why-kinhin).

## Requirements

- Apple Silicon Mac (arm64), macOS 15+
- [Tart](https://tart.run) — macOS runner VMs. `kinhin setup repair tart` installs it (or the setup
  window does); manual commands are in [Installing Tart](/guide/install#installing-tart)
- An access token for at least one CI platform: GitHub, Gitea, Forgejo or GitLab CE (see [Pick your forge](#pick-your-forge) and [Forge support](/guide/forges))
- Optional — Linux jobs. Three options — [apple/container](https://github.com/apple/container)
  microVMs (`brew install container && container system start`), Docker containers, or
  [Tart Linux VMs](/guide/runtimes#tart-linux-vms), which need nothing beyond tart itself;
  see the [comparison](/guide/runtimes#choosing-a-linux-runtime) for when to use each
  (macOS jobs always need Tart)
- ~60 GB free disk for the base image plus per-VM scratch

Sizing the fleet — CPU, memory, and storage recommendations — is covered in
[Hardware requirements & sizing](/guide/hardware).

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
to /Applications, and symlinks the `kinhin` CLI into your bin dir. Release artifacts are
Developer ID signed and notarized, so the app launches with **no Gatekeeper prompts** — the
Open-Anyway dance only applies to old releases or locally built copies.

## Pick your forge

One fleet can serve several forges at once. Start with one; you can add more later.

| Forge | Scope | Token | Store it with |
| ----- | ----- | ----- | ------------- |
| GitHub Actions | `owner/name` repo or org | PAT with `repo` scope | `kinhin auth set` |
| Gitea | `owner/name` or org, plus `instance` URL | Access token with runner rights | `kinhin auth set --gitea` |
| Forgejo | `owner/name` or org, plus `instance` URL | Access token with runner rights | `kinhin auth set --forgejo` |
| GitLab CE | `group/project` or group path, plus `instance` URL | Access token with `create_runner`, `manage_runner`, `read_api` | `kinhin auth set --gitlab` |

GitHub is the default account. Every other forge is an entry under `accounts:` in `config.yaml`, or
you can create it from the CLI:

```bash
kinhin auth add gitlab --gitlab --scope group/project --instance https://gitlab.example.com
```

```yaml
accounts:
  - name: gitlab
    forge: gitlab
    scope: "group/project"
    labels: ["macos"] # runner tags / labels that jobs select on
```

::: warning Beta
Only GitHub Actions has been tested against a real server (with Tart macOS VMs and apple/container). The other forges
are unit-tested but not yet live-tested; see [what has been tested](/guide/forges#what-has-been-tested). Please report how it goes.
:::

Each forge's setup details, token scopes and job-selection rules are in [Forge support](/guide/forges).

## First fleet (CLI)

```bash
# 0. Install tart (skipped if already installed)
kinhin setup repair tart

# 1. Create a starter config
kinhin config init
#    edit ~/Library/Application Support/Kinhin/config.yaml
#    -> set the accounts: entry (name/forge/scope) and the labels jobs will request

# 2. Store a token for your forge — it goes in your Keychain, not a file
kinhin auth set                  # GitHub PAT (repo scope)
kinhin auth set --gitlab         # or --gitea, --forgejo

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

That example is for GitHub. On other forges, jobs select runners by runner tags (GitLab) or `runs-on` labels
(Gitea, Forgejo). See [Forge support](/guide/forges).

Watch the fleet: `kinhin watch` (live) or `kinhin status` (one shot).

## First fleet (menu bar app)

Install with the one-liner above, then launch **kinhin** from Applications. The setup window
walks through the same steps — installing tart, creating the config, connecting a forge and storing
its token (the Connect form offers all seven), and preparing the image — then starts the fleet. The menu bar shows the number of live runner VMs.

::: tip Signed & notarized
Official releases are Developer ID signed and notarized — no right-click → **Open** needed.
Locally built copies are ad-hoc signed: clear Gatekeeper with `xattr -cr /Applications/kinhin.app`.
:::
