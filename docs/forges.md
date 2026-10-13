# Forge support

Which CI platforms kinhin serves, how to connect each one, and how to serve many accounts from one fleet.

[← Back to README](../README.md) · [Per-forge API notes](forges/README.md) (endpoints, versions)

A **forge** is a CI platform. kinhin speaks one protocol to all of them (get a registration token, list and remove
runners, report queued demand), and each platform implements it behind that interface. One fleet can serve **several
at once**: each VM is assigned to whichever forge has the most pending work, registers there, and is deleted when
its job finishes.

| Forge               | Status       | Runner agent   | Scope                                                  |
| ------------------- | ------------ | -------------- | ------------------------------------------------------ |
| GitHub Actions      | ✅ supported | actions-runner | `owner/name` repo or org, optional enterprise instance |
| Gitea Actions       | ✅ supported | gitea-runner   | `owner/name` repo or org, any instance                 |
| Forgejo Actions     | ✅ supported | gitea-runner   | `owner/name` repo or org, any instance                 |
| GitLab CE           | ✅ supported | gitlab-runner  | project or group path (`group/sub/proj`)               |
| Buildkite           | 🔜 planned   | —              | —                                                      |
| Azure Pipelines     | 🔜 planned   | —              | —                                                      |
| Bitbucket Pipelines | 🔜 planned   | —              | —                                                      |

## What has been tested

Gitea, Forgejo and GitLab CE run real jobs on every runtime in kinhin's [end-to-end suite](e2e-testing.md): a real
server in a container, a real runner, and a job whose result the forge itself reports. GitHub Actions has been run by
hand against github.com; its e2e lane needs a throwaway repository and is not run yet.

| Forge                 | Versions run                     | Runtimes                                                           |
| --------------------- | -------------------------------- | ------------------------------------------------------------------ |
| GitHub Actions        | github.com                       | Tart macOS VMs, apple/container                                    |
| Gitea Actions         | 1.24, 1.26                       | Tart macOS and Linux VMs, apple/container, Docker, host            |
| Forgejo Actions       | 11                               | Tart macOS and Linux VMs, apple/container, Docker, host            |
| GitLab CE             | 18.4                             | Tart macOS and Linux VMs, apple/container, Docker, host            |

Gitea 1.24 and older report no queued job until a runner exists, so they need `min_runners: 1`; Gitea 1.25+ and
Forgejo 11+ list queued jobs themselves and work with `min_runners: 0`. If something doesn't work for you, please open a
"Forge report" issue.

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

Self-managed GitLab CE 16.0 or later (run end to end on 18.4).

```yaml
accounts:
  - name: gitlab
    forge: gitlab
    scope: "group/project" # or a group path; subgroups nest
    instance: "https://gitlab.example.com"
    labels: ["macos"] # runner tags
```

Token: a personal, project or group access token with `create_runner`, `manage_runner` and `read_api` (or `api`)
scopes. Creating runners needs Maintainer on a project or Owner on a group. kinhin creates each runner through the API,
runs one job, and deletes it. A pending job counts as demand when every tag it asks for is one some pool advertises
(the runners carry the pool's labels). `vm.ephemeral: false` is rejected for a GitLab account, because the runner
deletes itself after one job. Only the tagged jobs of projects the token can read count; a single project the token
cannot read is an error, not an empty queue.

### Planned: Buildkite, Azure Pipelines, Bitbucket Pipelines

Support for these is planned for a later release and is not part of the beta. Follow the
[roadmap](beta-roadmap.md) for progress.

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

This flag applies only to self-hosted forges (Gitea, Forgejo, GitLab, or any GHES host). GitHub is
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
`.kinhin/config.yml` (or the older `.kinhin.yml`). GitHub, Gitea/Forgejo and GitLab supply both.

## More forges

Adding a platform means implementing the Forge protocol (client, bootstrap script, lifecycle notes); the autoscaler,
pool, checklist and status surfaces come for free. For the full step-by-step checklist (config, engine, runner bootstrap,
CLI, app, tests and docs), follow [Adding a forge](adding-a-forge.md); the protocol itself is in
`Sources/KinhinKit/Forges/Forge.swift`. Forges decide _who hands kinhin jobs_; [runtimes](runtimes.md) decide _where
those jobs run_.
