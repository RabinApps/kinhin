# Forge support (GitHub, GitLab, Gitea, Forgejo, Buildkite, Azure DevOps, Bitbucket, & the future)

Which CI platforms kinhin serves, how to add Gitea, Forgejo, GitLab, Buildkite, Azure DevOps and Bitbucket, and how to serve many accounts from one fleet.

[← Back to README](../README.md)

kinhin is built on a **Forge abstraction**: the engine speaks one unified protocol — mint a registration token, list/delete runners, report queued demand, track running jobs — and each CI platform implements it behind that interface. Today seven forges ship:

| Forge          | Status       | Runner agent                             | Scope shape                              |
| -------------- | ------------ | ---------------------------------------- | ---------------------------------------- |
| GitHub Actions | ✅ supported | actions-runner (GitHub's official agent) | `owner/name` repo or org                 |
| Gitea Actions  | ✅ supported | gitea-runner (formerly act_runner)       | `owner/name` repo or org on any instance |
| Forgejo        | ✅ supported | gitea-runner (wire-compatible)           | `owner/name` repo or org on any instance |
| GitLab CI/CD   | ✅ supported | gitlab-runner (GitLab's official agent)  | project or group path (`group/sub/proj`) |
| Buildkite      | ✅ supported | buildkite-agent (Buildkite's agent)      | `org/cluster` (cluster name or id)       |
| Azure Pipelines | ✅ supported | Azure Pipelines agent (vsts-agent)      | an agent pool in an organization         |
| Bitbucket Pipelines | ✅ supported | Bitbucket shell runner (Java-based)  | a workspace, or `workspace/repo-slug`    |

One fleet can serve **all of them at the same time** from a shared VM pool: each VM is assigned at spawn to whichever forge has the most pending work, registers there, and is deleted when its job finishes. Token-gating ties platforms to credentials — an agent is baked into the image and a forge attaches only when that platform's token exists.

## Adding Gitea

Store a Gitea access token with runner-management rights on the scope, then declare the forge as an `accounts:` entry in `config.yaml`:

```yaml
accounts:
  - name: gitea # the primary Gitea account keeps its original Keychain item
    forge: gitea
    instance: "https://gitea.example.com"
    scope: "owner/name" # or an org name
    labels: ["macos:host"] # jobs opt in via runs-on: macos:host
```

- Token: `kinhin auth set --gitea` (or the checklist's Gitea token row). Tokens live in the Keychain; replace one live without restarting.
- Image provisioning is **token-gated**: `kinhin image prepare` bakes the GitHub agent only if a GitHub PAT is stored, and the gitea-runner binary only if a Gitea token is stored — no credential, no agent. Both runner versions are resolved from the vendors' release feeds at prepare time (pinned fallback when offline).
- Gitea VMs are ephemeral like GitHub's: gitea-runner has no `--ephemeral`, so kinhin watches for all of the VM's runners to go idle and deletes the VM after a short grace period.
- Demand polling uses the scope's task-queue endpoints — real task entries with per-repo attribution when the instance exposes them (org scopes contribute to `queueByRepo`), with per-VM running attribution from busy runners; a `min_runners` floor keeps capacity available when an older instance reports nothing usable.

## Adding Forgejo

Forgejo is Gitea's upstream and is wire-compatible — the same `/api/v1` endpoints, the same task queue, the same gitea-runner binary. Declare it as an `accounts:` entry, alongside (or instead of) the Gitea one:

```yaml
accounts:
  - name: forgejo # the primary Forgejo account keeps its original Keychain item
    forge: forgejo
    instance: "https://code.example.com"
    scope: "owner/name" # or an org name
    labels: ["macos:host"]
```

Token: `kinhin auth set --forgejo`. `kinhin image prepare` bakes the gitea-runner binary when either a Gitea or a Forgejo token is stored — the same binary serves both platforms.

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

## Adding Buildkite

Buildkite is hosted only, so an account has no `instance`. Its scope is the organization slug and the cluster the agents join; every Buildkite account lives in `accounts:`:

```yaml
accounts:
  - name: ci # any account name; "buildkite" is not reserved
    forge: buildkite
    scope: "acme/Mac Fleet" # org slug / cluster name (or id)
    labels: ["queue=kinhin"] # agent tags, key=value; this is the default
```

- Add it from the CLI with `kinhin auth add ci --buildkite --scope acme/default [--token T]`. After that, `kinhin auth set --buildkite` stores or replaces the token of the first Buildkite account, and `--account NAME` targets any other one. The app's Connect and Add-an-account forms offer Buildkite too.
- Token: a REST API access token for the organization with the `read_agents`, `write_agents`, `read_builds`, `read_clusters` and `write_clusters` scopes (create it at buildkite.com/user/api-access-tokens). `kinhin auth status --buildkite` checks the scopes and that the cluster exists.
- Registration: when the account attaches, kinhin creates a cluster agent token named `kinhin: <account>` and revokes the account's previous one. Agents that are already connected keep running. The cluster must have a queue matching the `queue=` tag (the default is `kinhin`).
- Each agent runs one job (`buildkite-agent start --disconnect-after-job`) with the agent token in a private file. Buildkite only lists connected agents, so a finished agent drops out of the list and its instance is deleted. On the host runtime, an agent stopped mid-job by scale-down or engine stop is terminated along with its instance.
- Jobs select agents by agent query rules. A scheduled job counts as kinhin demand when the account's labels satisfy every rule. `*` works as a wildcard, and a job with no `queue` rule targets `queue=default`. Jobs the API places in another cluster are ignored. Demand is attributed per pipeline.
- Image provisioning is token-gated here too: `kinhin image prepare` and the Linux image bakes install buildkite-agent only when a Buildkite account has a stored token. On the host runtime, `kinhin setup repair host-agent` also installs it once a Buildkite account is configured. Its version comes from the agent's GitHub releases (pinned fallback when offline), verified against the release's `SHA256SUMS`.

## Adding Azure DevOps

Azure Pipelines agents join an **agent pool**. The account's `instance` is the organization URL (`https://dev.azure.com/acme`, or an Azure DevOps Server collection URL) and its scope is the pool's name:

```yaml
accounts:
  - name: ado # any account name
    forge: azuredevops
    instance: "https://dev.azure.com/acme"
    scope: "Mac Fleet" # the agent pool
    labels: ["kinhin"] # optional: capabilities pipelines demand
```

- Add it from the CLI with `kinhin auth add ado --azuredevops --scope "Mac Fleet" --instance https://dev.azure.com/acme [--token T]`. After that, `kinhin auth set --azuredevops` stores the token of the first Azure DevOps account, and `--account NAME` targets any other one. The app's Connect and Add-an-account forms offer Azure DevOps too.
- Token: a personal access token with only the **Agent Pools (Read & manage)** scope, from a user with the Administrator role on the pool. Azure agents register with this PAT, so **it is copied into every runner instance**. Use a dedicated token with nothing else in it. `kinhin auth status --azuredevops` checks that the pool exists and that the token can manage it.
- Each runner gets its own copy of the agent (an APFS clone on macOS, so it's instant; a plain copy in containers). It registers with `config.sh --unattended`, reading the PAT from a private file through `VSTS_AGENT_INPUT_TOKEN`. It runs one job (`run.sh --once`) and then removes itself from the pool, and the instance is deleted. In containers the agent runs as root (`AGENT_ALLOW_RUNASROOT=1`).
- Jobs pick agents by demands, and the account's labels are advertised as agent capabilities. A queued request counts as kinhin demand when its demands include every label: `kinhin` matches a `kinhin` demand, and `xcode=16` matches `xcode -equals 16`. **Without labels, every request in the pool counts**, so give kinhin its own pool, or set a label and add `demands: [kinhin]` to the pipelines it should run. Demand is attributed per pipeline.
- Image provisioning is token-gated: `kinhin image prepare` and the Linux image bakes install the agent only when an Azure DevOps account has a stored token. The Linux bake also runs the agent's `installdependencies.sh`. On the host runtime, `kinhin setup repair host-agent` installs the agent once an Azure DevOps account is configured. The version comes from the agent's GitHub releases (pinned fallback when offline) and is verified against the SHA-256 table in the release notes.

## Adding Bitbucket

Bitbucket Cloud self-hosted runners belong to a **workspace** (or a single repository). The account's scope is the workspace slug, or `workspace/repo-slug` to serve one repository — there is no instance URL, Bitbucket is hosted only:

```yaml
accounts:
  - name: bb # any account name
    forge: bitbucket
    scope: "acme" # a workspace, or acme/api-server for one repository
    labels: ["xcode=16"] # optional: extra runs-on selectors the runners advertise
```

- Add it from the CLI with `kinhin auth add bb --bitbucket --scope acme [--token T]`; `kinhin auth set --bitbucket` stores the token of the first Bitbucket account and `--account NAME` targets any other one. The app's Connect and Add-an-account forms offer Bitbucket too.
- Token: a **workspace access token** (workspace scopes) or a **repository access token** (`workspace/repo` scopes) with the runner and pipeline scopes — app passwords do not cover runners. The token stays in the Mac's Keychain; runners authenticate with their own OAuth client credentials.
- Registration: when an instance spawns, kinhin creates a runner on the forge per runner name with the labels `self.hosted`, `macos` (or `linux.shell` in containers) plus the account's labels, and captures the OAuth client id/secret the create response returns — **the secret is shown only once**, so kinhin stores the whole bundle and the bootstrap hands it to the runner through a private file. Because runners are created per instance, teardown and the engine's cleanup delete them through the API.
- The runner stays connected across steps (Bitbucket's runner protocol has no single-job mode), so the instance goes once its runners have been **busy and then idle for a grace period** — the same watch the Gitea family uses. On the host runtime, a runner stopped mid-job by scale-down or engine stop is terminated along with its instance.
- Demand: the public API has no queued-steps endpoint, so kinhin polls the active pipelines' steps — the one repository, or the workspace's recently active repositories (one page of repos, one page of pipelines each), which keeps the poll inside Bitbucket's roughly 1000 requests/hour budget. The step payload does not expose `runs_on` yet, so every active step counts as demand; the runner itself matches `runs-on:` labels at the forge. Demand is attributed per repository.
- The runner is Java-based: images bake the runner package **and a Temurin JDK 25** (verified against Temurin's per-asset SHA-256; the package itself is pinned by digest, since Atlassian publishes no checksums). Image provisioning is token-gated as with the other forges, and `kinhin setup repair host-agent` installs the runner for host routes.

## Multiple accounts

Serve as many GitHub orgs/repos, Gitea/Forgejo instances, GitLab projects/groups, Buildkite clusters, Azure DevOps pools and Bitbucket workspaces as you like from one fleet. Every forge is an `accounts:` entry; the ones named `github`, `gitea`, and `forgejo` are the primary accounts (their tokens keep the original Keychain items — nothing to migrate), and additional entries each carry their own token:

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
- A top-level `repo:`, `gitea:`, or `forgejo:` key is rejected by the parser — declare every forge in `accounts:`. Older kinhin builds ignore the `accounts:` key, so don't share one config with a build that predates it.
- `kinhin auth status --json` keeps its `forges` entries and adds an `accounts` array.

## Plain `http://` instances

Self-hosted Gitea, Forgejo, GitLab and Azure DevOps instances must use `https://`: the access token is sent with every request, so over `http://` it crosses the network in cleartext. `localhost`, `127.0.0.1` and `[::1]` are exempt. For an instance on a network you trust, opt in per account:

```yaml
accounts:
  - name: lab-gitea
    forge: gitea
    scope: "me/repo"
    instance: "http://gitea.lan:3000"
    allow_insecure_http: true # the token is sent in cleartext
```

The flag only lifts the https requirement for that account. Redirects still have to stay on the same host and may not downgrade from https to http, and pagination links must match the configured API host. kinhin logs a warning each time such an account attaches. GitHub, Buildkite and Bitbucket are always https, so the key is rejected on them.

## More forges are planned

The Forge protocol was designed so new platforms slot in without touching the engine. Forgejo landed as a thin re-brand of the Gitea forge, GitLab as a per-runner adapter (`GitLabForge`), Buildkite as a cluster-token adapter (`BuildkiteForge`), Azure DevOps as a PAT-registered pool adapter (`AzureDevOpsForge`), and Bitbucket as a per-runner adapter with idle-grace exit (`BitbucketForge`). Sourcehut is a candidate for the next one. Adding one means implementing the Forge protocol (client + bootstrap script + lifecycle notes) — the autoscaler, VM pool, checklist, status surfaces, and tests all come for free. See `Sources/KinhinKit/Forges/Forge.swift` for the contract.

Forges decide _who hands kinhin jobs_; [runtimes](runtimes.md) decide _where those jobs execute_.
