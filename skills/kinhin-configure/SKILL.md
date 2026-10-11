---
name: kinhin-configure
description: Edit or write a kinhin config.yaml safely - accounts per forge, labels, capacity, runtimes and routes, token scopes. Use when the user wants to connect a forge, change labels, runners or VM sizing, or fix a config that fails validation.
---

# Configure kinhin

**Beta status:** GitHub, Gitea, Forgejo and GitLab CE are supported. Gitea, Forgejo and GitLab CE have run real jobs on
every runtime; GitHub on Tart macOS VMs and apple/container. Buildkite, Azure DevOps and Bitbucket are planned.

## Rules

- The config is `~/Library/Application Support/Kinhin/config.yaml` (capital K). `kinhin config init` writes a
  commented starter. Edits made through the CLI or app preserve comments. Routes, projects and labels reload live in a
  running daemon.
- **Never put tokens in the config.** Tokens live in the Keychain: `kinhin auth set [--account NAME]`.
- Every forge goes under `accounts:`. The old top-level `repo:`, `gitea:` and `forgejo:` keys are rejected.
- After every edit run `kinhin config validate`. It exits 3 when the config is invalid.
- Prefer `kinhin help` and `kinhin config init` output over this page if they disagree.
- **Public repository?** Fork pull requests must not reach the fleet: follow `docs/open-source.md` (runner group
  without public repos, fork PRs routed to hosted runners, approval for external contributors). For such a fleet set
  `tart_softnet: true` and `runners_per_vm: 1`, keep `share_cache` and `repo_file` off, scope the account to
  `owner/name`, and never add a `host` route.

## Account entries

Account names use lowercase letters, digits, `-` and `_`. `github`, `gitea` and `forgejo` are the primary names.

```yaml
accounts:
  # GitHub: scope is owner/repo, or a bare org name
  - {name: github, forge: github, scope: "owner/repo"}
  # Gitea or Forgejo (forge: forgejo for Forgejo)
  - {name: gitea, forge: gitea, instance: "https://gitea.example.com", scope: "owner/name", labels: ["macos:host"]}
  # GitLab CE (16.0+). A job's tags must include every label.
  - {name: gitlab, forge: gitlab, instance: "https://gitlab.example.com", scope: "group/project", labels: ["macos"]}
```

Buildkite, Azure DevOps and Bitbucket are planned and not supported yet; do not configure them.

Self-hosted Gitea, Forgejo and GitLab must use `https://` unless the host is loopback or the account sets
`allow_insecure_http: true`.

## Token scopes

| Forge | Token needs |
| --- | --- |
| GitHub | PAT with `repo` (org runner-admin for an org scope) |
| Gitea / Forgejo | Access token with runner-management rights |
| GitLab | `create_runner`, `manage_runner`, `read_api` or `api`; Maintainer on a project or Owner on a group |

`kinhin auth add NAME --<forge> --scope S` prints the exact requirements for that forge.

## How a job reaches the fleet

| Forge | Job targeting |
| --- | --- |
| GitHub, Gitea, Forgejo | `runs-on:` labels |
| GitLab | Runner tags |

A job must request all of the account's labels (default `["self-hosted","macos","arm64"]`). A repo `.kinhin.yml` is
only honored on GitHub, Gitea/Forgejo and GitLab.

## Capacity and VM settings

| Key | Default / notes |
| --- | --- |
| `min_runners` / `max_runners` | 0 / 2 |
| `runners_per_vm` | 1 to 8. Packs several jobs into one VM. |
| `poll_interval` | 20 seconds, minimum 5 |
| `vm` | `cpu: 4`, `memory_gb: 8`, `ephemeral: true` |
| `reserve` | `cpu: 2`, `memory_gb: 4`, `disk_gb: 10` left for the host |
| `image` / `base_image` | `tahoe-base`, and a Tart image ref (optionally `@sha256:` pinned) or local VM name |
| `auto_resume` | false |

Capacity is `min(max_runners, (cores - reserve.cpu)/vm.cpu, (RAM - reserve.memory_gb)/vm.memory_gb, free_disk/disk_per_vm)`.
`disk_per_vm` is 50 GB for Tart and 8 GB for container slots. macOS allows only two macOS VMs per Mac. `kinhin doctor`
prints the cap and which constraint binds.

## Runtimes and routes

Runtimes: `tart` (default), `appleContainer`, `docker`, `host`. Route precedence: workflow route, repo route,
`runs-on:` label, default.

```yaml
runtimes:
  default: tart
  budget: {tart: 0.6, appleContainer: 0.4}
  routes:
    - {pattern: "acme/api", runtime: appleContainer}
    - {pattern: "acme/scripts", runtime: host, consent: true}
```

Or use the CLI: `kinhin runtimes route add <pattern> <tart|appleContainer|docker|host> [--consent]`.

To move **one workflow** to a runtime (editing its `runs-on:` and reconciling the route automatically), use the
`kinhin-route-workflow` skill — it also decides *which* runtime fits the workflow.

Host mode runs jobs unisolated on the Mac. It needs `consent: true`, `default: host` is rejected, every account must be
scoped to one `owner/name`, it works for GitHub, Gitea and Forgejo only, and workflows opt in with
`runs-on: [kinhin-host]` after `kinhin setup repair host-agent`. Warn the user before suggesting it for untrusted code.

## Common validation failures

- Old top-level `repo:`, `gitea:` or `forgejo:` key: move it under `accounts:`.
- `default: host` in `runtimes`: pick `tart`, `appleContainer` or `docker`.
- `http://` instance on a self-hosted forge: use `https://` or set `allow_insecure_http: true` deliberately.
- Image names starting with `kinhin-` or `orchard-` are reserved.

## More

- [Forge setup](https://github.com/RabinApps/kinhin/blob/main/docs/forges.md)
- [Runtimes](https://github.com/RabinApps/kinhin/blob/main/docs/runtimes.md)
- [Scaling](https://github.com/RabinApps/kinhin/blob/main/docs/scaling.md)
