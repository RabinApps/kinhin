# Forge API reference

What kinhin assumes about each forge's API, checked against the forge's own documentation.

[← Back to README](../../README.md) · [Setup guide](../forges.md)

[Forge support](../forges.md) tells you how to set a forge up. These pages record what kinhin sends, which endpoints it calls, and how that compares with each forge's current API docs or published spec. Each page ends with audit findings and a "Verified" date. Re-run the audit when a forge ships a new API version, and update the date.

<!-- docs-sync:begin forges -->
Forge IDs recognized by the config and the CLI (`ForgeID`): `github`, `gitlab`, `gitea`, `forgejo`, `buildkite`, `azuredevops`, `bitbucket`.
<!-- docs-sync:end forges -->

| Forge | Page | API versioning | Self-hosted | Live-tested |
|---|---|---|---|---|
| GitHub | [github.md](github.md) | `X-GitHub-Api-Version` header (`2022-11-28`, `2026-03-10`) | Optional enterprise instance: GHES `https://<hostname>/api/v3`, GHEC `https://api.<subdomain>.ghe.com` | Yes |
| Gitea | [gitea.md](gitea.md) | By server release | Yes (`instance`) | No |
| Forgejo | [gitea.md](gitea.md) | By server release | Yes (`instance`) | No |
| GitLab | [gitlab.md](gitlab.md) | `/api/v4`, features by server release | Yes (`instance`) | No |
| Buildkite | [buildkite.md](buildkite.md) | `/v2` | n/a (SaaS control plane) | No |
| Azure DevOps | [azuredevops.md](azuredevops.md) | `api-version` query parameter (kinhin sends `7.0`) | Yes (Server) | No |
| Bitbucket Cloud | [bitbucket.md](bitbucket.md) | `/2.0` | Cloud only | No |

## How each forge is used

| | Registration | Exit | Demand source | Label filter |
|---|---|---|---|---|
| GitHub | Shared token, 1 h | Deregisters | Workflow runs, then jobs | `labels ⊆ job.labels` |
| Gitea, Forgejo | Shared token, long-lived | Idle grace | `/actions/tasks` | None |
| GitLab | One runner per VM | Deregisters | `/projects/{id}/jobs` per project | `job.tag_list ⊆ pool labels` |
| Buildkite | Cluster agent token | Deregisters | Org builds | Agent query rules (`kinhin-runtime=<x>` carries a pool marker) |
| Azure DevOps | PAT | Deregisters | Pool job requests | Demands (labels are capabilities) |
| Bitbucket | One runner per VM | Idle grace | Steps of active pipelines, `runs-on` from `bitbucket-pipelines.yml` | Self-hosted steps only |

## Audit summary (2026-10-01)

Highest-impact findings, most severe first. Details and evidence are in each page.

1. **Gitea 1.26 and later: registration-token method.** The spec only has `POST`; kinhin sends `GET`. Forgejo only has `GET`. See [gitea.md](gitea.md#audit-findings).
2. **Gitea and Forgejo demand detection does not match the published specs.** The task-list response key, the unsupported `status` parameter and the missing `runner_name` are all differences from the spec. Better endpoints exist on newer releases. Needs a check against a live server before any change.
3. **Gitea and Forgejo runner list and delete** are missing on Gitea before 1.24 and on every released Forgejo checked (through v14).
4. **GitHub org scope relied on an undocumented endpoint** (`/orgs/{org}/actions/runs`). Resolved (2026-10-01): kinhin no longer calls it and reads each repository's runs via the documented `/repos/{repo}/actions/runs`.
5. **Azure DevOps demand relies on an undocumented path** (`pools/{id}/jobrequests`) and is pinned to `api-version=7.0`, which Azure DevOps Server 2020 and older reject.
6. **GitHub is live-tested and now supports GHES and GHEC data residency through the optional `instance` field**; it still does not use JIT runner config.


7. **Buildkite and Bitbucket**: no mismatches with the docs or spec; minor efficiency notes only.

## Live-run lessons (2026-10-09)

The first live runs of GitHub and Gitea showed classes of defect that kinhin's stubbed-HTTP tests had not caught, so the GitLab, Buildkite, Azure DevOps and Bitbucket start-up scripts, label rules and demand reads were re-read against them. The fixes are recorded in each forge's page under "Audit findings (live-run lessons, 2026-10-09)", each with a "Still to verify live" list. **They were made by code reading and unit tests with fakes only; none of these four forges is live-tested** and the table above is unchanged.

| Forge | Headline fixes |
|---|---|
| [GitLab](gitlab.md#audit-findings-live-run-lessons-2026-10-09) | Pool labels win for runner tags; demand is job tags subset of pool labels; `vm.ephemeral: false` rejected; read failures surface; MR pipelines flagged as forks |
| [Buildkite](buildkite.md#audit-findings-live-run-lessons-2026-10-09) | Agent failures visible; `kinhin-runtime=<x>` tag for runtime markers; per-process token description (legacy tokens need one manual revoke); queue validated |
| [Azure DevOps](azuredevops.md#audit-findings-live-run-lessons-2026-10-09) | Foreground registration, PAT never on disk; labels become capabilities; `ephemeral: false` honoured; offline agents reaped; unverified: empty pool with `demands:` may fail fast |
| [Bitbucket](bitbucket.md#audit-findings-live-run-lessons-2026-10-09) | Runner command quoting, JDK layout, `updated_on` decode, host teardown fixed; demand from the pipeline file; Tart Linux needs a `linux` label |

## Where versions matter (input for a version setting)

| Forge | What would vary with a selected version |
|---|---|
| GitHub | `X-GitHub-Api-Version` value (no behavior difference for kinhin's endpoints today); base path `/api/v3` for GHES, or `api.<subdomain>.ghe.com` for GHEC data residency |
| Gitea | Registration-token HTTP method, runner list and delete availability, demand endpoint (`/actions/jobs` from 1.25) |
| Forgejo | Registration-token method (GET), demand endpoint (`/actions/runners/jobs?labels=` from 11), runner list and delete (trunk only) |
| GitLab | Minimum 16.0; runner API availability |
| Azure DevOps | `api-version` (5.0 to 7.x depending on Server release) |
| Buildkite, Bitbucket | None |

## Conventions

- "Verified" means checked against the forge's documentation or published OpenAPI or swagger spec on the stated date. Specs show what a server documents, not how it behaves at runtime.
- Code references are `file:line` and drift as the code changes; the endpoint tables name the function so the line can be re-found.
