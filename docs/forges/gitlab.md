# GitLab

How kinhin talks to GitLab CI, and how that compares with GitLab's current REST API docs.

[← Back to README](../../README.md) · [Forge reference index](README.md) · [Setup guide](../forges.md)

## Overview

| | |
|---|---|
| Forge id | `gitlab` |
| Hosting | gitlab.com (default) or self-managed. `instance` is optional (`GitLabModels.swift:10`). |
| Scope | A project path or a group path. Paths nest (`group/sub/project`) and are percent-encoded with `%2F`. The client resolves `GET /projects/{enc}` and falls back to `GET /groups/{enc}`. |
| Source | `Sources/KinhinKit/Forges/GitLabClient.swift`, `GitLabForge.swift`, `GitLabModels.swift` |
| Live-tested | No (stubbed HTTP). |

## Auth

`PRIVATE-TOKEN: <token>` (`GitLabClient.swift:288`), matching GitLab's docs. `TokenRequirements.gitlab` asks for scopes `create_runner`, `manage_runner`, `read_api` (or `api`), and the Maintainer role on a project or Owner on a group.

GitLab's docs tie scopes to endpoints: `POST /user/runners` needs `create_runner`; runner deletion and updates need `manage_runner`.

## API version and base URL

| | We send | Documented (verified 2026-10-01) |
|---|---|---|
| Base | `{instance}/api/v4` (`GitLabClient.swift:275`) | `/api/v4` |
| Versioning | None | REST API v4 is semantically versioned. New features land in v4 without a minor version, and experimental or flag-gated elements can be removed without notice. |

The server release decides what exists. The code requires **GitLab 16.0 or later** for runner creation (`GitLabModels.swift:142`) and reads `GET /version` to check (`GitLabClient.swift:210`). The docs page for `POST /user/runners` does not state which release introduced it, so the 16.0 floor comes from the code and was not re-verified here. The docs now reference GitLab 18.x and 19.x releases, so the API is moving on.

## Endpoints used

| Method | Path | Purpose | Code |
|---|---|---|---|
| GET | `/projects/{enc}`, then `/groups/{enc}` | Resolve scope, permission probe | `GitLabClient.swift:47,54` |
| POST | `/user/runners` | Create a runner and receive its authentication token | `GitLabClient.swift:100` |
| GET | `/projects/{id}/runners?type=project_type`, `/groups/{id}/runners?type=group_type` | List runners | `GitLabClient.swift:109,112` |
| DELETE | `/runners/{id}` | Remove a runner | `GitLabClient.swift:117` |
| GET | `/projects/{id}/jobs?scope[]=pending\|running&per_page=100` | Demand and running jobs | `GitLabClient.swift:158` |
| GET | `/groups/{id}/projects?include_subgroups=true&archived=false&simple=true&order_by=last_activity_at&last_activity_after=…` | Projects to poll for a group scope | `GitLabClient.swift:185` |
| GET | `/projects?membership=true&min_access_level=40`, `/groups?min_access_level=50` | Pickers | `GitLabClient.swift:67,76` |
| GET | `/personal_access_tokens/self` | Token scope check | `GitLabClient.swift:203` |
| GET | `/version` | Minimum version check | `GitLabClient.swift:211` |

The `POST /user/runners` body is `{description, tag_list, run_untagged: false, runner_type: project_type|group_type, project_id|group_id}`. GitLab's docs list the same fields and add `instance_type`.

## Registration flow

- Registration mode `perRunner`: one runner is created per VM runner name (`GitLabForge.swift:68-77`). Exit semantics `deregisters`.
- `tag_list` is the account labels plus the pool labels.
- Each runner runs `gitlab-runner run-single --description ... --executor shell` and removes itself afterwards (`RunnerBootstrap+GitLab.swift:68`).
- `mintRegistrationToken` throws: kinhin never uses GitLab's legacy shared registration tokens.
- The authentication token is returned once. GitLab's docs: it "cannot be retrieved again".

## Demand and label matching

- GitLab has no group-wide job queue. For a group, the client reads at most 50 recently active projects per poll, 8 at a time. The project list is cached for 300 s, projects with no activity for 24 h are skipped, and projects that return 403 or 404 are skipped with a warning.
- `isOurs` (`GitLabForge.swift:~112`) requires `labels ⊆ job.tag_list`. An empty label set, or an untagged job, never matches.

## Pagination, rate limits, retries

- Offset pagination, following `X-Next-Page`, `per_page=100`, up to 50 pages (`GitLabClient.swift:230-245`). GitLab documents `per_page` max 100.
- `withTransientRetry` on network errors, 429 and 5xx. There is no `RateLimit-*` header handling.

## Self-hosted notes and minimum versions

- Minimum GitLab 16.0 (enforced).
- `instance` is the base URL; a path prefix is preserved (`GitLabClient.swift:273`).
- Self-managed instances can disable or rate-limit parts of the API; the client treats 403 and 404 on per-project reads as "skip and warn".

## Version sensitivity

| Item | Detail |
|---|---|
| Runner creation | `POST /user/runners` requires a release that has it (16.0 per the code). |
| `type=project_type` on group runner lists | GitLab marks it deprecated and scheduled for removal in a future REST version. kinhin uses it on the project list, not the group list, so it is not affected today. |
| Runner response attributes | `active`, `ip_address`, `version`, `revision`, `platform`, `architecture` are deprecated; moved to the GraphQL `CiRunnerManager`. kinhin should not rely on them. |
| Jobs listing | `scope` accepts many statuses; `waiting_for_callback` and `canceling` exist on newer releases. kinhin uses only `pending` and `running`. |

## Audit findings

1. **Pagination mode.** GitLab recommends keyset pagination for large job lists and orders `/projects/:id/jobs` by id descending. Offset pagination works but gets slower and is limited on large collections. With `scope[]=pending|running` the result sets are small, so this is low risk.
2. **Scope names.** `TokenRequirements` already matches the docs (`create_runner`, `manage_runner`, `read_api`).
3. **`/jobs` has no group endpoint**, so large groups depend on the 50-project and 24-hour limits. That is a documented API gap, not a bug; keep the limitation visible in the setup guide.
4. **The 16.0 floor is unverified** against GitLab's release notes (the fetched page omits the introduction release).

## Verified

2026-10-01, against:
- <https://docs.gitlab.com/api/users/> (create runner)
- <https://docs.gitlab.com/api/runners/>
- <https://docs.gitlab.com/api/jobs/>
- <https://docs.gitlab.com/api/rest/>
