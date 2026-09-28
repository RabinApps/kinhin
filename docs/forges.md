# Forge support (GitHub, Gitea, Forgejo, GitLab, & the future)

Which CI platforms kinhin serves, how to add Gitea, Forgejo and GitLab, and how to serve many accounts from one fleet.

[← Back to README](../README.md)

kinhin is built on a **Forge abstraction**: the engine speaks one unified protocol — mint a registration token, list/delete runners, report queued demand, track running jobs — and each CI platform implements it behind that interface. Today four forges ship:

| Forge          | Status       | Runner agent                             | Scope shape                              |
| -------------- | ------------ | ---------------------------------------- | ---------------------------------------- |
| GitHub Actions | ✅ supported | actions-runner (GitHub's official agent) | `owner/name` repo or org                 |
| Gitea Actions  | ✅ supported | gitea-runner (formerly act_runner)       | `owner/name` repo or org on any instance |
| Forgejo        | ✅ supported | gitea-runner (wire-compatible)           | `owner/name` repo or org on any instance |
| GitLab CI/CD   | ✅ supported | gitlab-runner (GitLab's official agent)  | project or group path (`group/sub/proj`) |

One fleet can serve **all of them at the same time** from a shared VM pool: each VM is assigned at spawn to whichever forge has the most pending work, registers there, and is deleted when its job finishes. Token-gating ties platforms to credentials — an agent is baked into the image and a forge attaches only when that platform's token exists.

## Adding Gitea

Store a Gitea access token with runner-management rights on the scope, then declare the forge in `config.yaml`:

```yaml
gitea:
  instance: "https://gitea.example.com"
  scope: "owner/name" # or an org name
  labels: ["macos:host"] # jobs opt in via runs-on: macos:host
```

- Token: `kinhin auth set --gitea` (or the checklist's Gitea token row). Both tokens live in the Keychain; replace either live without restarting.
- Image provisioning is **token-gated**: `kinhin image prepare` bakes the GitHub agent only if a GitHub PAT is stored, and the gitea-runner binary only if a Gitea token is stored — no credential, no agent. Both runner versions are resolved from the vendors' release feeds at prepare time (pinned fallback when offline).
- Gitea VMs are ephemeral like GitHub's: gitea-runner has no `--ephemeral`, so kinhin watches for all of the VM's runners to go idle and deletes the VM after a short grace period.
- Demand polling uses the scope's task-queue endpoints — real task entries with per-repo attribution when the instance exposes them (org scopes contribute to `queueByRepo`), with per-VM running attribution from busy runners; a `min_runners` floor keeps capacity available when an older instance reports nothing usable.

## Adding Forgejo

Forgejo is Gitea's upstream and is wire-compatible — the same `/api/v1` endpoints, the same task queue, the same gitea-runner binary. Declare it alongside (or instead of) `gitea:`:

```yaml
forgejo:
  instance: "https://code.example.com"
  scope: "owner/name" # or an org name
  labels: ["macos:host"]
```

Token: `kinhin auth set --forgejo` (or a `forge: forgejo` entry in `accounts:`). `kinhin image prepare` bakes the gitea-runner binary when either a Gitea or a Forgejo token is stored — the same binary serves both platforms.

## Adding GitLab

GitLab has no top-level section; every GitLab account lives in `accounts:` (gitlab.com and self-managed GitLab 16.0 or later):

```yaml
accounts:
  - name: gitlab # any account name; "gitlab" is not reserved
    forge: gitlab
    scope: "group/project" # or a group path; subgroups nest (group/sub/project)
    instance: "https://gitlab.example.com" # optional, gitlab.com when absent (no /api)
    labels: ["macos"] # runner tags; defaults to the top-level labels:
```

- Add it from the CLI with `kinhin auth add gitlab --gitlab --scope group/project [--instance URL] [--token T]`. After that, `kinhin auth set --gitlab` stores or replaces the token of the first GitLab account, and `--account NAME` targets any other one. The app's Connect and Add-an-account forms offer GitLab too.
- Token: use a personal, project or group access token with the `create_runner`, `manage_runner` and `read_api` (or `api`) scopes. Creating runners needs Maintainer on a project or Owner on a group. `kinhin auth set --gitlab` (without `--token`) prints the exact token-settings links for the configured instance before it asks for the token.
- GitLab has no shared registration token. kinhin creates each runner through the API (`POST /user/runners`). It runs one job (`gitlab-runner run-single --max-builds 1`) and deletes itself afterwards. On the host runtime, a runner stopped mid-job by scale-down or engine stop is terminated along with its instance.
- Jobs select runners by tags. A pending job counts as kinhin demand when its tags include every one of the account's labels. Group scopes attribute demand per project.
- Image provisioning is token-gated here too: `kinhin image prepare` bakes gitlab-runner only when a GitLab account has a stored token. On the host runtime, `kinhin setup repair host-agent` also installs gitlab-runner once a GitLab account is configured. Its version comes from GitLab's release feed, with a pinned fallback.

## Multiple accounts

Serve as many GitHub orgs/repos, Gitea/Forgejo instances, and GitLab projects/groups as you like from one fleet. `repo:`, `gitea:`, and `forgejo:` remain the built-in accounts (named `github`, `gitea`, and `forgejo`, tokens under the original Keychain items — nothing to migrate); add more with an `accounts:` list, each with its own token:

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

- `kinhin auth add work --github --scope bigco` writes the entry (add `--token X` to store the token too); `kinhin auth set --account work` stores or replaces its token, `kinhin auth list` shows every account, `kinhin auth remove work` deletes the entry and its token. The app's Connect form has the same controls under **More accounts**.
- Each account has its own token in the Keychain (`github-pat:work`), its own registration-token cache, and its own attach/retry state: one account with a bad token is detached with the reason in the status line while the others keep serving. New VMs go to the account with the most unmet demand.
- `repo:` may be omitted when every account is in `accounts:`. Older kinhin builds ignore the `accounts:` key, so don't share one config with a build that predates it.
- `kinhin auth status --json` keeps its `forges` entries and adds an `accounts` array.

## More forges are planned

The Forge protocol was designed so new platforms slot in without touching the engine. Forgejo landed as a thin re-brand of the Gitea forge, and GitLab as a per-runner adapter (`GitLabForge`). Sourcehut, Buildkite, and others are candidates. Adding one means implementing the Forge protocol (client + bootstrap script + lifecycle notes) — the autoscaler, VM pool, checklist, status surfaces, and tests all come for free. See `Sources/KinhinKit/Forges/Forge.swift` for the contract.

Forges decide _who hands kinhin jobs_; [runtimes](runtimes.md) decide _where those jobs execute_.
