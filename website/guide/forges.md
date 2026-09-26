# Forge support (GitHub, Gitea, Forgejo, & the future)

Kinhin is built on a **Forge abstraction**: the engine speaks one unified protocol — mint a
registration token, list/delete runners, report queued demand, track running jobs — and each
CI platform implements it behind that interface. Today three forges ship:

| Forge          | Status       | Runner agent                             | Scope shape                                  |
| -------------- | ------------ | ---------------------------------------- | -------------------------------------------- |
| GitHub Actions | ✅ supported | actions-runner (GitHub's official agent) | `RabinApps/name` repo or org                 |
| Gitea Actions  | ✅ supported | gitea-runner (formerly act_runner)       | `RabinApps/name` repo or org on any instance |
| Forgejo        | ✅ supported | gitea-runner (wire-compatible)           | `RabinApps/name` repo or org on any instance |

One fleet can serve **all of them at the same time** from a shared VM pool: each VM is assigned
at spawn to whichever forge has the most pending work, registers there, and is deleted when its
job finishes.

## Adding Gitea

Store a Gitea access token with runner-management rights on the scope, then declare the forge
in `config.yaml`:

```yaml
gitea:
  instance: "https://gitea.example.com"
  scope: "RabinApps/name" # or an org name
  labels: ["macos:host"] # jobs opt in via runs-on: macos:host
```

- Token: `kinhin auth set --gitea`. Both tokens live in the Keychain; replace either live
  without restarting.
- Image provisioning is **token-gated**: `kinhin image prepare` bakes the GitHub agent only if
  a GitHub PAT is stored, and the gitea-runner binary only if a Gitea token is stored.
- Gitea VMs are ephemeral like GitHub's: gitea-runner has no `--ephemeral`, so kinhin watches
  for all of the VM's runners to go idle and deletes the VM after a short grace period.
- Demand polling uses the scope's task-queue endpoints — real task entries with per-repo
  attribution when the instance exposes them (org scopes contribute to `queueByRepo`), with
  per-VM running attribution from busy runners; a `min_runners` floor keeps capacity available
  when an older instance reports nothing usable.

## Adding Forgejo

Forgejo is Gitea's upstream and is wire-compatible: the same `/api/v1` endpoints, the same
task queue, the same gitea-runner binary. Declare it alongside (or instead of) `gitea:`:

```yaml
forgejo:
  instance: "https://code.example.com"
  scope: "acme/api" # or an org name
  labels: ["macos:host"]
```

- Token: `kinhin auth set --forgejo` (or a `forge: forgejo` entry in `accounts:`).
- `kinhin image prepare` bakes the gitea-runner binary when either a Gitea or a Forgejo token
  is stored — the same binary serves both platforms.
- All Gitea semantics apply unchanged: long-lived registration tokens, idle-grace ephemeral
  watches, and task-queue demand polling.

## Multiple accounts

`repo:` and `gitea:` are the built-in accounts, named `github` and `gitea`. To serve more — a
second GitHub org, another Gitea instance — add an `accounts:` list; every entry has its own
scope and its own token:

```yaml
accounts:
  - name: work # lowercase letters, digits, - or _ (not "github"/"gitea"/"forgejo")
    forge: github
    scope: "bigco" # org, or owner/name
  - name: home-gitea
    forge: gitea
    scope: "me/repo"
    instance: "https://git.home.lan"
    labels: ["macos:host"]
```

- `kinhin auth add work --github --scope bigco` writes the entry; `kinhin auth set --account work`
  stores its token in the Keychain (`github-pat:work`). `kinhin auth list` and
  `kinhin auth remove NAME` manage them. The app's Connect form has the same controls under
  **More accounts**.
- One account failing (bad token, unreachable server) is detached with the reason shown in the
  status line and retried with backoff; the others keep serving.
- New VMs go to the account with the most unmet demand, and register with that account's token.
- `repo:` is optional when every account is listed under `accounts:`.
- Older builds ignore `accounts:`, so avoid sharing one config file with a build that predates it.

## More forges are planned

The Forge protocol was designed so new platforms slot in without touching the engine: Forgejo
(Gitea's upstream, wire-compatible), GitLab, Sourcehut, Buildkite, and others are all
candidates. Adding one means implementing the Forge protocol (client + bootstrap script +
lifecycle notes) — the autoscaler, VM pool, checklist, status surfaces, and tests all come for
free. See `Sources/KinhinKit/Forge.swift` for the contract.
