# Forge API reference

What kinhin assumes about each forge's API, checked against the forge's own documentation.

[← Back to README](../../README.md) · [Setup guide](../forges.md)

[Forge support](../forges.md) tells you how to set a forge up. These pages record what kinhin sends, which endpoints it calls, and how that compares with each forge's current API docs or published spec. Each page ends with a "Verified" date. Re-check when a forge ships a new API version, and update the date.

<!-- docs-sync:begin forges -->
Forge IDs recognized by the config and the CLI (`ForgeID`): `github`, `gitlab`, `gitea`, `forgejo`, `buildkite`, `azuredevops`, `bitbucket`.
<!-- docs-sync:end forges -->

| Forge | Page | API versioning | Self-hosted | Status |
|---|---|---|---|---|
| GitHub | [github.md](github.md) | `X-GitHub-Api-Version` header (`2022-11-28`, `2026-03-10`) | Optional enterprise instance: GHES `https://<hostname>/api/v3`, GHEC `https://api.<subdomain>.ghe.com` | Supported |
| Gitea | [gitea.md](gitea.md) | By server release | Yes (`instance`) | Supported |
| Forgejo | [gitea.md](gitea.md) | By server release | Yes (`instance`) | Supported |
| GitLab CE | [gitlab.md](gitlab.md) | `/api/v4`, features by server release | Yes (`instance`) | Supported |
| Buildkite | [buildkite.md](buildkite.md) | `/v2` | n/a (SaaS control plane) | Planned |
| Azure DevOps | [azuredevops.md](azuredevops.md) | `api-version` query parameter (kinhin sends `7.0`) | Yes (Server) | Experimental |
| Bitbucket Cloud | [bitbucket.md](bitbucket.md) | `/2.0` | Cloud only | Planned |

The pages for planned forges describe implementation work in progress; those forges are not supported yet. Azure DevOps is experimental: one user has run real jobs against Azure DevOps Services, but the project's own live lane has not passed.

## How each forge is used

| | Registration | Exit | Demand source | Label filter |
|---|---|---|---|---|
| GitHub | Shared token, 1 h | Deregisters | Workflow runs, then jobs | `labels ⊆ job.labels` |
| Gitea, Forgejo | Shared token, long-lived | Idle grace | `/actions/jobs?status=queued` (Gitea 1.25+), `/actions/runners/jobs?labels=` (Forgejo 11+), else `/actions/tasks` | `runs-on` against the pools' labels |
| GitLab | One runner per VM | Deregisters | `/projects/{id}/jobs` per project | `job.tag_list ⊆ pool labels` |

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
