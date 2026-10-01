# Forge support (GitHub, GitLab, Gitea, Forgejo, Buildkite, Azure DevOps, Bitbucket, & the future)

Kinhin is built on a **Forge abstraction**: the engine speaks one unified protocol — mint a
registration token, list/delete runners, report queued demand, track running jobs — and each
CI platform implements it behind that interface. Today seven forges ship:

| Forge          | Status       | Runner agent                             | Scope shape                              |
| -------------- | ------------ | ---------------------------------------- | ---------------------------------------- |
| GitHub Actions | ✅ supported | actions-runner (GitHub's official agent) | `owner/name` repo or org                 |
| Gitea Actions  | ✅ supported | gitea-runner (formerly act_runner)       | `owner/name` repo or org on any instance |
| Forgejo        | ✅ supported | gitea-runner (wire-compatible)           | `owner/name` repo or org on any instance |
| GitLab CI/CD   | ✅ supported | gitlab-runner (GitLab's official agent)  | project or group path (`group/sub/proj`) |
| Buildkite      | ✅ supported | buildkite-agent (Buildkite's agent)      | `org/cluster` (cluster name or id)       |
| Azure Pipelines | ✅ supported | Azure Pipelines agent (vsts-agent)      | an agent pool in an organization         |
| Bitbucket Pipelines | ✅ supported | Bitbucket shell runner (Java-based)  | a workspace, or `workspace/repo-slug`    |

One fleet can serve **all of them at the same time** from a shared VM pool: each VM is assigned
at spawn to whichever forge has the most pending work, registers there, and is deleted when its
job finishes.

## Adding Gitea

Store a Gitea access token with runner-management rights on the scope, then declare the forge
as an `accounts:` entry in `config.yaml`:

```yaml
accounts:
  - name: gitea # the primary Gitea account keeps its original Keychain item
    forge: gitea
    instance: "https://gitea.example.com"
    scope: "owner/name" # or an org name
    labels: ["macos:host"] # jobs opt in via runs-on: macos:host
```

- Token: `kinhin auth set --gitea`. Tokens live in the Keychain; replace one live without
  restarting.
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
task queue, the same gitea-runner binary. Declare it as an `accounts:` entry, alongside (or
instead of) the Gitea one:

```yaml
accounts:
  - name: forgejo # the primary Forgejo account keeps its original Keychain item
    forge: forgejo
    instance: "https://code.example.com"
    scope: "acme/api" # or an org name
    labels: ["macos:host"]
```

- Token: `kinhin auth set --forgejo`.
- `kinhin image prepare` bakes the gitea-runner binary when either a Gitea or a Forgejo token
  is stored — the same binary serves both platforms.
- All Gitea semantics apply unchanged: long-lived registration tokens, idle-grace ephemeral
  watches, and task-queue demand polling.

## Adding GitLab

GitLab has no top-level section; every GitLab account lives in `accounts:` (gitlab.com and
self-managed GitLab 16.0 or later):

```yaml
accounts:
  - name: gitlab # any account name; "gitlab" is not reserved
    forge: gitlab
    scope: "group/project" # or a group path; subgroups nest (group/sub/project)
    instance: "https://gitlab.example.com" # optional, gitlab.com when absent (no /api)
    labels: ["macos"] # runner tags; defaults to the top-level labels:
```

- Add it from the CLI with
  `kinhin auth add gitlab --gitlab --scope group/project [--instance URL] [--token T]`; after
  that, `kinhin auth set --gitlab` stores or replaces the token of the first GitLab account, and
  `--account NAME` targets any other one. The app's Connect and Add-an-account forms offer GitLab
  too.
- Token: a personal, project or group access token with the `create_runner`, `manage_runner` and
  `read_api` (or `api`) scopes; creating runners needs Maintainer on a project or Owner on a
  group. `kinhin auth set --gitlab` (without `--token`) prints the exact token-settings links for
  the configured instance before it asks for the token.
- GitLab has no shared registration token: kinhin creates each runner through the API
  (`POST /user/runners`), it runs one job (`gitlab-runner run-single --max-builds 1`) and deletes
  itself afterwards; on the host runtime, a runner stopped mid-job by scale-down or engine stop is
  terminated along with its instance.
- Jobs select runners by tags: a pending job counts as kinhin demand when its tags include every
  one of the account's labels, and group scopes attribute demand per project.
- Image provisioning is token-gated here too: `kinhin image prepare` bakes gitlab-runner only when
  a GitLab account has a stored token, and `kinhin setup repair host-agent` also installs
  gitlab-runner once a GitLab account is configured. Its version comes from GitLab's release
  feed, with a pinned fallback.

## Adding Buildkite

Buildkite is hosted only, so an account has no `instance`. Its scope is the organization slug
and the cluster the agents join:

```yaml
accounts:
  - name: ci # any account name; "buildkite" is not reserved
    forge: buildkite
    scope: "acme/Mac Fleet" # org slug / cluster name (or id)
    labels: ["queue=kinhin"] # agent tags, key=value; this is the default
```

- Add it with `kinhin auth add ci --buildkite --scope acme/default`, then store its token with
  `kinhin auth set --buildkite` (the first Buildkite account) or `--account NAME`. The app's
  Connect and Add-an-account forms offer Buildkite too.
- Token: a REST API access token with the `read_agents`, `write_agents`, `read_builds`,
  `read_clusters` and `write_clusters` scopes.
- When the account attaches, kinhin creates a cluster agent token named `kinhin: <account>`,
  replacing its previous one. The cluster needs a queue matching the `queue=` tag (default
  `kinhin`).
- Each agent runs one job (`--disconnect-after-job`); once it disconnects, its instance is
  deleted.
- A scheduled job counts as kinhin demand when the account's labels satisfy all of its agent
  query rules (`*` is a wildcard; no `queue` rule means `queue=default`).
- `kinhin image prepare`, the Linux bakes and `kinhin setup repair host-agent` install
  buildkite-agent once a Buildkite account is set up, verified against the release's
  `SHA256SUMS`.

## Adding Azure DevOps

Azure Pipelines agents join an agent pool. The account's `instance` is the organization URL (or
an Azure DevOps Server collection URL), and its scope is the pool's name:

```yaml
accounts:
  - name: ado
    forge: azuredevops
    instance: "https://dev.azure.com/acme"
    scope: "Mac Fleet" # the agent pool
    labels: ["kinhin"] # optional: capabilities pipelines demand
```

- Add it with `kinhin auth add ado --azuredevops --scope "Mac Fleet" --instance URL`, then
  `kinhin auth set --azuredevops` (the first Azure DevOps account) or `--account NAME`.
- Token: a PAT with only the **Agent Pools (Read & manage)** scope, from an Administrator of
  the pool. Agents register with this PAT, so it is copied into every runner instance. Use a
  dedicated token.
- Each runner gets its own copy of the agent and registers unattended with the PAT from a private
  file. It runs one job (`run.sh --once`) and removes itself from the pool.
- A queued request counts as kinhin demand when its demands include every label (`kinhin`, or
  `xcode -equals 16` for `xcode=16`). Without labels, every request in the pool counts, so give
  kinhin its own pool.
- `kinhin image prepare`, the Linux bakes and `kinhin setup repair host-agent` install the agent
  once an Azure DevOps account is set up, verified against the release notes' SHA-256 table.

## Adding Bitbucket

Bitbucket Cloud self-hosted runners belong to a workspace (or a single repository). The scope is
the workspace slug, or `workspace/repo-slug` for one repository — Bitbucket is hosted only:

```yaml
accounts:
  - name: bb
    forge: bitbucket
    scope: "acme" # a workspace, or acme/api-server for one repository
    labels: ["xcode=16"] # optional: extra runs-on selectors the runners advertise
```

- Add it with `kinhin auth add bb --bitbucket --scope acme`, then `kinhin auth set --bitbucket`
  (the first Bitbucket account) or `--account NAME`.
- Token: a **workspace access token** (or repository access token) with the runner and pipeline
  scopes — app passwords do not cover runners. The token stays in the Keychain; runners
  authenticate with their own OAuth client credentials.
- Registration: kinhin creates a runner on the forge per runner name with `self.hosted`,
  `macos` (or `linux.shell` in containers) plus the account's labels, and captures the OAuth
  client id/secret the create response returns (the secret is shown only once). Runners are
  deleted through the API when the instance is.
- The runner stays connected across steps, so the instance goes once its runners have been busy
  and then idle for a grace period — the same watch the Gitea family uses.
- Demand: there is no queued-steps endpoint, so kinhin polls the active pipelines' steps — the
  one repository, or the workspace's recently active repositories (inside Bitbucket's ~1000
  requests/hour budget). The step payload does not expose `runs_on` yet, so every active step
  counts; the runner itself matches `runs-on:` labels at the forge.
- The runner is Java-based: images bake the package plus a Temurin JDK 25 (verified against
  Temurin's per-asset SHA-256; the package is pinned by digest — Atlassian publishes none).

## Multiple accounts

Every forge is an `accounts:` entry; the ones named `github`, `gitea`, and `forgejo` are the
primary accounts (their tokens keep the original Keychain items). To serve more — a second
GitHub org, another Gitea or Forgejo instance, a GitLab project or group, a Buildkite
cluster, an Azure DevOps pool, a Bitbucket workspace — add more entries;
every one has its own scope and its own token:

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
- A top-level `repo:`, `gitea:`, or `forgejo:` key is rejected by the parser — declare every
  forge in `accounts:`.
- Older builds ignore `accounts:`, so avoid sharing one config file with a build that predates it.

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

The Forge protocol was designed so new platforms slot in without touching the engine. Forgejo
landed as a thin re-brand of the Gitea forge, GitLab as a per-runner adapter
(`GitLabForge`), Buildkite as a cluster-token adapter (`BuildkiteForge`), Azure DevOps as a
PAT-registered pool adapter (`AzureDevOpsForge`), and Bitbucket as a per-runner adapter with
idle-grace exit (`BitbucketForge`). Sourcehut is a candidate. Adding one means implementing
the Forge protocol (client + bootstrap script + lifecycle notes) — the autoscaler, VM pool,
checklist, status surfaces, and tests all come for free. See
`Sources/KinhinKit/Forges/Forge.swift` for the contract.
