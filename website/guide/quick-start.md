# Quick start

Kinhin turns your Apple Silicon Mac into an autoscaling fleet of ephemeral self-hosted CI
runners. This page gets you from zero to a working fleet. New here? Read [why kinhin exists](/guide/why-kinhin).

## Requirements

- Apple Silicon Mac (arm64), macOS 15+
- [Tart](https://tart.run) — macOS runner VMs. `kinhin setup repair tart` installs it (or the setup
  window does); manual commands are in [Installing Tart](/guide/install#installing-tart)
- An access token for at least one CI platform: GitHub, Gitea, Forgejo or GitLab CE (see [Pick your forge](#pick-your-forge) and [Forge support](/guide/forges))
- Optional — Linux jobs. Three options: [apple/container](https://github.com/apple/container)
  microVMs (recommended; `kinhin setup repair container`), Docker containers, or
  [Tart Linux VMs](/guide/runtimes#tart-linux-vms), which need nothing beyond tart itself.
  See [installing a Linux runtime](/guide/install#installing-a-linux-runtime) and the
  [comparison](/guide/runtimes#choosing-a-linux-runtime) (macOS jobs always need Tart)
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
Gitea, Forgejo and GitLab CE have run real jobs on every runtime; GitHub Actions on Tart macOS VMs and
apple/container. Azure Pipelines is experimental (smoke-tested by one user, not by the project). Buildkite and Bitbucket Pipelines are planned, not supported yet. See
[what has been tested](/guide/forges#what-has-been-tested), and please report how it goes.
:::

Each forge's setup details, token scopes and job-selection rules are in [Forge support](/guide/forges).

## Set up your first fleet

Do it yourself, or hand the job to an AI agent such as Claude Code: the agent runs the same steps, and you only store
the token.

<AudienceTabs>
<template #human>

### From the terminal

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

### From the menu bar app

Install with the one-liner above, then launch **kinhin** from Applications. The setup window
walks through the same steps — installing tart, creating the config, connecting a forge and storing
its token, and preparing the image — then starts the fleet. The menu bar shows the number of live runner VMs.

::: tip Signed & notarized
Official releases are Developer ID signed and notarized — no right-click → **Open** needed.
Locally built copies are ad-hoc signed: clear Gatekeeper with `xattr -cr /Applications/kinhin.app`.
:::

</template>
<template #agent>

### 1. Give your agent the kinhin skills

kinhin ships seven agent skills (install, configure, add a forge account, route a workflow, operate, images and
toolchains, troubleshoot). Every command in them is checked against the real CLI.

**Any agent** (Claude Code, Codex, Cursor, Gemini, OpenCode, …) — one command with the open
[`skills`](https://github.com/vercel-labs/skills) installer:

```bash
npx skills add RabinApps/kinhin --skill '*' --global
```

It asks which agents to install into (`--agent claude-code` picks one, `--yes` skips the questions). Drop `--global`
to install into the current project instead, and run `npx skills update` later to pick up new versions.

**Claude Code, as a plugin** — the repository is also a plugin marketplace:

```bash
claude plugin marketplace add RabinApps/kinhin
claude plugin install kinhin@kinhin
```

An agent with no skill support can read this page instead: give it `https://kinhin.dev/guide/quick-start`.

### 2. Paste this prompt

Fill in the line that names your forge, then hand it over:

```text
Install kinhin on this Mac and set up a CI fleet for:
  <GitHub org "acme"  |  GitHub repo acme/app  |  Gitea https://git.example.com, repo acme/app  |  GitLab group acme>

Use the kinhin skills (kinhin-install, kinhin-configure, kinhin-add-forge-account).
- First check the Mac qualifies (arm64, macOS 15+, about 60 GB free disk). Stop and tell me if it does not.
- Install kinhin and Tart, write the config, and run `kinhin config validate`.
- Never ask me to paste a token into this chat. When a token is needed, tell me which permissions it needs,
  ask me to run `kinhin auth set --account <name>` in my own terminal, and wait until I say it is done.
- Ask me before `kinhin image prepare` (it downloads tens of GB) and before `kinhin daemon install`.
- Never run `kinhin reset`, never add a `host` route, and never pass --yes to cleanup or prune unasked.
- Finish with `kinhin doctor` and `kinhin setup status`, then tell me the `runs-on:` label my workflows should use.
```

### 3. Do the one step that is yours

The agent never sees your token. When it asks, create the token with the permissions it lists
([Forge support](/guide/forges) has them per forge), then store it yourself:

```bash
kinhin auth set --account github     # or the account name the agent gave you
```

`kinhin auth set` hides what you type and keeps the token in your Keychain, never in a file. Tell the agent when it is
done and it carries on.

### 4. Let the agent watch the fleet (optional)

`kinhin mcp` gives the agent read access to status, doctor, logs and the live pipeline, plus pause and resume. It never
exposes reset, cleanup or token commands.

```bash
claude mcp add kinhin -- kinhin mcp
```

Other agents take the same server as `{"command": "kinhin", "args": ["mcp"]}`. The full tool list and the safety
rules agents follow are in [AI agents & MCP](/guide/agents).

::: tip Public repository?
Tell the agent, and point it at [Running kinhin for an open-source project](/guide/open-source): fork pull requests
must not reach your Mac.
:::

</template>
</AudienceTabs>
