# Forge support

Which CI platforms kinhin serves, how to connect each one, and how to serve many accounts from one fleet.

[← Back to README](../README.md) · [Per-forge API notes](forges/README.md) (endpoints, versions, audit)

A **forge** is a CI platform. kinhin speaks one protocol to all of them (get a registration token, list and remove
runners, report queued demand), and each platform implements it behind that interface. One fleet can serve **all of
them at once**: each VM is assigned to whichever forge has the most pending work, registers there, and is deleted when
its job finishes.

| Forge               | Status         | Runner agent                  | Scope                                                  |
| ------------------- | -------------- | ----------------------------- | ------------------------------------------------------ |
| GitHub Actions      | ✅ live-tested | actions-runner                | `owner/name` repo or org, optional enterprise instance |
| Gitea Actions       | 🧪 untested    | gitea-runner                  | `owner/name` repo or org, any instance                 |
| Forgejo             | 🧪 untested    | gitea-runner                  | `owner/name` repo or org, any instance                 |
| GitLab CI/CD        | 🧪 untested    | gitlab-runner                 | project or group path (`group/sub/proj`)               |
| Buildkite           | 🧪 untested    | buildkite-agent               | `org/cluster`                                          |
| Azure Pipelines     | 🧪 untested    | Azure Pipelines agent         | an agent pool in an organization                       |
| Bitbucket Pipelines | 🧪 untested    | Bitbucket shell runner (Java) | a workspace, or `workspace/repo-slug`                  |

## What has been tested

This is a beta. **Live-tested** means it was run against a real server. **Untested** means the code has unit tests
(stubbed HTTP, fake shells) but has **never been run against a real instance**. Unit tests show the code matches our
reading of each API, not that the real service agrees, so expect surprises there.

| Forge                                                      | Live-tested | Unit-tested |
| ---------------------------------------------------------- | ----------- | ----------- |
| GitHub Actions + Tart macOS VMs                            | yes         | yes         |
| GitHub Actions + apple/container (Linux)                   | yes         | yes         |
| Gitea, Forgejo, GitLab, Buildkite, Azure DevOps, Bitbucket | **no**      | yes         |

Runtimes follow the same rule: Tart macOS VMs and apple/container are live-tested; Docker, Tart Linux VMs and host mode
are not (see [Runtimes](runtimes.md)).
If you try one, please open a "Forge report" issue and say whether it worked.

## Connecting a forge

Every forge is an entry under `accounts:` in `config.yaml`, with its own token in the Keychain. You can add one with
`kinhin auth add <name> --<forge> --scope <scope>` or in the app's Connect form. `kinhin auth set --<forge>` stores or
replaces the token (`--account NAME` targets a specific account).

Agents are baked into the image only when a token for that forge exists, so no credential means no agent.

### GitHub

The main path. The [Quick start](../website/guide/quick-start.md) walks through the token and the first fleet.

```yaml
accounts:
  - name: github
    forge: github
    scope: "acme/widgets" # or an org name
    instance: "https://github.example.com" # optional; github.com when absent
    labels: [] # unused for GitHub
```

Token: a personal or classic personal access token with the permissions in `TokenRequirements.github(scope:instance:)`.
The account's `instance` is optional: leave it out for github.com. When it is present it must be a base URL —
GHES (`https://github.example.com`) or GHEC data residency (`https://acme.ghe.com`) — and `allow_insecure_http`
applies to it the same way as for self-hosted Gitea/Forgejo/GitLab.

### Gitea and Forgejo

Forgejo is Gitea's upstream and wire-compatible, so both use the same runner binary and the same setup.

```yaml
accounts:
  - name: gitea # or "forgejo" with forge: forgejo
    forge: gitea
    instance: "https://gitea.example.com"
    scope: "owner/name" # or an org name
    labels: ["macos:host"] # jobs opt in via runs-on: macos:host
```

Token: an access token with runner-management rights on the scope (`kinhin auth set --gitea` or `--forgejo`). The
runner has no single-job mode, so kinhin deletes the VM shortly after its runners go idle.

### GitLab

Works with gitlab.com and self-managed GitLab 16.0 or later.

```yaml
accounts:
  - name: gitlab
    forge: gitlab
    scope: "group/project" # or a group path; subgroups nest
    instance: "https://gitlab.example.com" # optional; gitlab.com when absent
    labels: ["macos"] # runner tags
```

Token: a personal, project or group access token with `create_runner`, `manage_runner` and `read_api` (or `api`)
scopes. Creating runners needs Maintainer on a project or Owner on a group. kinhin creates each runner through the API,
runs one job, and deletes it. A pending job counts as demand when its tags include every one of the account's labels.

### Buildkite

Hosted only, so there is no `instance`.

```yaml
accounts:
  - name: ci
    forge: buildkite
    scope: "acme/Mac Fleet" # org slug / cluster name (or id)
    labels: ["queue=kinhin"] # agent tags; this is the default
```

Token: a REST API token with `read_agents`, `write_agents`, `read_builds`, `read_clusters` and `write_clusters`.
`kinhin auth status --buildkite` checks the scopes and that the cluster exists. The cluster needs a queue matching the
`queue=` tag. Each agent runs one job and disconnects.

### Azure DevOps

Agents join an **agent pool**. `instance` is the organization URL and `scope` is the pool name.

```yaml
accounts:
  - name: ado
    forge: azuredevops
    instance: "https://dev.azure.com/acme"
    scope: "Mac Fleet"
    labels: ["kinhin"] # optional: capabilities pipelines demand
```

Token: a PAT with only **Agent Pools (Read & manage)**, from a user with the Administrator role on the pool. Azure
agents register with this PAT, so **it is copied into every runner**: use a dedicated token with nothing else in it.
**Without labels, every request in the pool counts as demand**, so give kinhin its own pool, or set a label and add
`demands: [kinhin]` to the pipelines it should run.

### Bitbucket

Hosted only. The scope is a workspace, or `workspace/repo-slug` for one repository.

```yaml
accounts:
  - name: bb
    forge: bitbucket
    scope: "acme" # or acme/api-server
    labels: ["xcode=16"] # optional: extra runs-on selectors
```

Token: a **workspace** or **repository access token** with the runner and pipeline scopes (app passwords don't cover
runners). The runner is Java-based, so images also bake a Temurin JDK. Bitbucket's public API has no queued-steps
endpoint, so kinhin polls active pipelines, and every active step counts as demand.

## Multiple accounts

Serve as many orgs, instances and pools as you like from one fleet. Accounts named `github`, `gitea` and `forgejo` are
the primary ones; any other name works for additional accounts:

```yaml
accounts:
  - name: work # lowercase letters, digits, - or _
    forge: github
    scope: "bigco"
  - name: home-gitea
    forge: gitea
    scope: "me/repo"
    instance: "https://git.home.lan"
```

- `kinhin auth add work --github --scope bigco` writes the entry, `kinhin auth list` shows every account, and
  `kinhin auth remove work` deletes the entry and its token. The app's Connect form has the same controls.
- Each account has its own token and attach state. One account with a bad token is detached with the reason in the
  status line while the others keep serving.
- Top-level `repo:`, `gitea:` and `forgejo:` keys are rejected; declare every forge in `accounts:`.

## Plain `http://` instances

Self-hosted instances must use `https://` because the token is sent with every request; `localhost`, `127.0.0.1` and
`[::1]` are exempt. When an instance is http, the account opt-in is `allow_insecure_http: true`:

```yaml
accounts:
  - name: lab-gitea
    forge: gitea
    scope: "me/repo"
    instance: "http://gitea.lan:3000"
    allow_insecure_http: true # the token is sent in cleartext
```

kinhin logs a warning each time such an account attaches.

This flag applies only to self-hosted forges (Gitea, Forgejo, GitLab, Azure DevOps, or any GHES host). GitHub is
hosted by default, so it must never use `http://`; when a GitHub account does declare `instance: http://...`, the
account's `allow_insecure_http` opt-in lets the token cross the network in cleartext.

## Enterprise instances

GitHub accounts can carry an optional enterprise host. It is required to use GitHub Enterprise Server or GitHub
Enterprise Cloud with data residency, but otherwise optional: a blank or absent `instance` means github.com.

```yaml
accounts:
  - name: ghes
    forge: github
    scope: "bigco"
    instance: "https://github.example.com" # GHES base URL
    labels: [] # unused for GitHub
```

```yaml
accounts:
  - name: ghec
    forge: github
    scope: "bigco"
    instance: "https://acme.ghe.com" # GHEC data residency host
    labels: [] # unused for GitHub
```

The runner's own registration `--url` is still `https://<host>/<scope>`; only the API and web links change. GitHub
still requires https: `allow_insecure_http` is accepted for GHES accounts, but https is always expected.

## Per-project toolchains and forges

[Per-project toolchains](toolchains.md#per-project-toolchains) need the branch or tag a job runs at and the repo's
`.kinhin.yml`. GitHub, Gitea/Forgejo and GitLab supply both. Buildkite, Bitbucket and Azure DevOps don't, so their jobs
use only `projects[].toolchains`, or the plain base image.

## More forges

Adding a platform means implementing the Forge protocol (client, bootstrap script, lifecycle notes); the autoscaler,
pool, checklist and status surfaces come for free. For the full step-by-step checklist (config, engine, runner bootstrap,
CLI, app, tests and docs), follow [Adding a forge](adding-a-forge.md); the protocol itself is in
`Sources/KinhinKit/Forges/Forge.swift`. Forges decide _who hands kinhin jobs_; [runtimes](runtimes.md) decide _where
those jobs run_.
