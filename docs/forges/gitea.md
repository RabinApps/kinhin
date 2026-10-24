# Gitea and Forgejo

How kinhin talks to Gitea Actions and Forgejo Actions, and how that compares with their current API specs. Forgejo is served by the same client (`GiteaClient`); this page notes where the two diverge.

[← Back to README](../../README.md) · [Forge reference index](README.md) · [Setup guide](../forges.md)

## Overview

| | |
|---|---|
| Forge ids | `gitea`, `forgejo` (`GiteaForge.swift:102` only switches the id and display name) |
| Hosting | Self-hosted (Gitea, Forgejo) or hosted (gitea.com, codeberg.org). `instance` is required. |
| Scope | `owner/name` or an org. `actionsBase` is `/api/v1/repos/{scope}/actions` or `/api/v1/orgs/{scope}/actions` (`GiteaClient.swift:36,44`). |
| Source | `Sources/KinhinKit/Forges/GiteaClient.swift`, `GiteaForge.swift`, `GiteaModels.swift` |
| Live-tested | Gitea 1.24 and 1.26, Forgejo 11, on every runtime, by the [end-to-end suite](../e2e-testing.md). Unit tests stub HTTP (`StubProtocol`); `FakeGitea` in `KinhinTestSupport` is pinned to `GiteaForge` by contract tests. |

## Auth

`Authorization: token <T>` (`GiteaClient.swift:262`), plus `Accept: application/json` and `User-Agent: Kinhin/1.0`. Required permissions are in `TokenRequirements.gitea(scope:instance:)`: the token's user must own the repository or organization (or be an administrator), and the token needs the repository or organization scopes listed there.

## API version and base URL

| | We send | Documented (verified 2026-10-01) |
|---|---|---|
| Base | `{instance}/api/v1` | `/api/v1` on both Gitea and Forgejo |
| Version header or parameter | None | None. The API is versioned by the server release, not by the request. |

Because the request carries no version, the **server release decides what exists**. The next sections compare releases.

## Endpoints used

| Method | Path | Purpose | Code |
|---|---|---|---|
| GET, then POST | `{actionsBase}/runners/registration-token` | Mint a registration token; doubles as the permission probe. Gitea 1.26+ only accepts POST, so a 404 or 405 is retried with POST | `GiteaClient.fetchRegistrationToken()` |
| GET | `{actionsBase}/runners` | List runners | `GiteaClient.swift:169` |
| DELETE | `{actionsBase}/runners/{id}` | Remove a runner | `GiteaClient.swift:184` |
| GET | `{actionsBase}/jobs?status=queued&page=1&limit=50` | Queued demand (Gitea 1.25+); the status of an unclaimed job is `queued` | `GiteaClient.jobs(runnerLabels:)` |
| GET | `{actionsBase}/runners/jobs?labels=a,b` | Queued demand (Forgejo 11+); `labels` is the runner's label set, returns a bare array or `null` | `GiteaClient.jobs(runnerLabels:)` |
| GET | `{actionsBase}/tasks?status=waiting&page=1&limit=50` | Queued demand fallback for older servers | `GiteaClient.swift:191` |
| GET | `{actionsBase}/tasks?status=running&page=1&limit=50` | Running tasks, attributed by `runner_name` | `GiteaClient.swift:218` |
| GET | `/api/v1/repos/search?limit=50&private=true&sorted=updated&page=N` | Repository picker | `GiteaClient.swift:91` |

## Pipeline view

The running task (`/actions/tasks?status=running`, matched by `runner_name`) is shown as one job with its run link,
title and start time where the server reports them. Gitea and Forgejo have no stable public step list, so the view is
job-level.

No output is shown: there is no stable public log endpoint across Gitea and Forgejo releases.

## Registration flow

- Registration mode `sharedLongLived`, exit semantics `idleGrace` (`GiteaForge.swift`).
- The token is fetched once in `GiteaForge.make` and reused by every runner.
- Runner start: `gitea-runner register --no-interactive --token --labels`, then `gitea-runner daemon` (`RunnerBootstrap+Linux.swift:179,184`). The binary comes from gitea.com releases (`RunnerBootstrap+Verification.swift:62`).

## Demand and label matching

- Gitea 1.25+ (`/actions/jobs?status=queued`) and Forgejo 11+ (`/actions/runners/jobs?labels=`) report real queued jobs. Forgejo is asked about every label the fleet's pools register, plus the account's labels and kinhin's pool markers; it returns only the jobs whose `runs-on` fits.
- Older servers fall back to the task queue, where a `min_runners` floor (`demandFloor`) applies when the endpoint answers with zero entries. A failed request keeps the previous scaling state.
- A runner is busy when the runner list reports `busy: true` (Gitea reports a working runner as `status: online`); where the server has no runner list, see [below](#forgejo-has-no-runner-list).
- Jobs opt in to a pool through `runs-on`; the pool's labels are used at register time.

## Pagination, rate limits, retries

`limit=50` with one page for tasks and a short-page stop for repositories. No rate-limit handling beyond `withTransientRetry` (2 retries, backoff 1 s then 2 s, on network errors, 429 and 5xx).

## What each server release offers

Built by diffing the swagger specs shipped in each release (`templates/swagger/v1_json.tmpl` at the release tag; Forgejo from codeberg.org). "Reg-token" is `…/actions/runners/registration-token`.

### Gitea

| Release | Reg-token | List and delete runners | `/actions/tasks` | `/actions/jobs?status=` |
|---|---|---|---|---|
| 1.22 | GET | no | no | no |
| 1.23 | GET | no | yes (`page`, `limit`) | no |
| 1.24 | GET and POST | yes | yes | no |
| 1.25 | GET and POST | yes | yes | yes (`/actions/jobs?status=`) |
| 1.26 and trunk | **POST only** | yes (adds `disabled`, PATCH) | yes | yes (`/actions/jobs?status=`) |

### Forgejo

| Release | Reg-token | List and delete runners | `/actions/tasks` | `/actions/runners/jobs?labels=` |
|---|---|---|---|---|
| 7.0 | GET | no | no | no |
| 11.0 | GET | no | yes (`page`, `limit`) | yes (`/actions/runners/jobs?labels=`) |
| 12.0, 14.0 | GET | no | yes | yes (`/actions/runners/jobs?labels=`) |
| trunk (16 dev) | GET | yes (`GET`/`DELETE …/actions/runners`, `POST` to create) | yes (adds `status`) | yes (`/actions/runners/jobs?labels=`) |

## Version sensitivity

| Item | Affects | Detail |
|---|---|---|
| Registration-token method | Gitea ≥ 1.26 | Only POST exists there; kinhin sends GET first and falls back to POST on a 404 or 405. Forgejo and Gitea ≤ 1.25 answer GET. |
| Runner list and delete | Gitea < 1.24, Forgejo through at least v14 | Endpoints absent, so `listRunners` and `deleteRunner` get a 404. kinhin watches running tasks instead; see [Forgejo has no runner list](#forgejo-has-no-runner-list). |
| `/actions/tasks` | Gitea < 1.23, Forgejo < 11 | Endpoint absent. |
| Demand source | Gitea ≥ 1.25, Forgejo ≥ 11 | Better endpoints are used: Gitea `/actions/jobs?status=queued`, Forgejo `/actions/runners/jobs?labels=` (the account's labels plus every label the fleet's pools register, and kinhin's pool markers). They report real queued jobs before any runner exists, so `min_runners: 0` works. Verified live on Gitea 1.26.4 and Forgejo 11; Gitea 1.24 and older still need `min_runners: 1`. |
| Job repository, branch, commit | Gitea ≥ 1.25, Forgejo ≥ 11 | Neither queue names the repository: Gitea 1.26 puts it only in the job's `url` (read from there), Forgejo not at all (a repo-scoped account's jobs are its repository; an org-scoped Forgejo account's are unattributed, so repo routes do not apply to them). Branch and commit are `head_branch`/`head_sha`. |
| Workflow routes | Gitea, Forgejo | **Not supported.** Neither the job nor the run names the workflow (`name:`), only the workflow file, so `owner/repo@Workflow` routes never match; repo routes and labels do. |
| Runner binary | all | `act_runner` and `gitea-runner` naming. kinhin installs `gitea-runner`; confirm Forgejo's own runner (`forgejo-runner`) is acceptable before relying on the gitea.com download for Forgejo. |

## Forgejo has no runner list

Probed live on Forgejo 11 (`codeberg.org/forgejo/forgejo:11`) with a registered `gitea-runner` v5 and a running job:

| Endpoint | Answer |
|---|---|
| `GET …/actions/runners`, `…/runners/{id}`, org, user and admin variants | 404 |
| `GET …/actions/runs`, `…/actions/jobs`, `…/actions/workflows` | 404 |
| `GET …/actions/tasks` (any `?status=`) | 200 `{"workflow_runs": [...], "total_count": n}`; the filter is ignored and finished runs are included; newest-updated first; each entry has `id`, `name` (the job), `status` (`running`, `success`, `failure`, ...), `run_number`, `head_branch`, `head_sha`, `display_title`, `url`, timestamps and **no runner name**. A job no runner has fetched yet is not listed. |
| `GET …/actions/runners/jobs?labels=a` | 200, the waiting jobs for those labels (`id`, `name`, `runs_on`, `task_id`, `status: "waiting"`), `null` without a label match |

So there is no way to ask the server which runner is busy. The exit watch (`idleGrace`, which every Gitea-family runner
needs because `gitea-runner` daemons never deregister) therefore changes rule when the runner list answers 404 (the 404
is remembered for ten minutes, not asked on every poll):

- **Registered**: the registration script succeeded (it runs `gitea-runner register` synchronously) before the watch
  starts, so every expected runner counts as registered at once.
- **Busy**: any task of the scope that is not finished (`running`, or a status kinhin does not recognize, or none)
  makes every runner of the account busy. Tasks are read from the first pages of `/actions/tasks` (up to 200
  newest-updated entries; a running task is touched by its runner every few seconds, so it stays near the top).
- **Done**: no unfinished task for the idle grace (30 s), then a fresh read confirms it before the instance is deleted.
  A runner that never gets a job is reclaimed the same way once the scope is quiet.

The trade-off is deliberate: an instance whose own job ended stays until the rest of the scope's jobs end too, and an
idle instance in a busy scope stays until it quiets (or the 6 h watch deadline). A leaked instance is cheaper than one
deleted mid-job. The server keeps a stale offline runner record per finished instance because there is no delete
endpoint (whether the server prunes them was not checked).

The task list is read as `workflow_runs` (or `entries`, the older shape), filtered to `running`/`waiting` client-side,
since the server ignores `?status=`.

## Open notes

1. **Workflow routes are not supported** (see Version sensitivity).
2. **Runner list and delete need newer servers**: Gitea 1.24+; Forgejo only on trunk. kinhin works without them as
   described above.
3. **Rate limits**: no handling beyond the transient-retry policy.

## Verified

2026-10-01, against:
- Gitea swagger specs at release tags v1.22.6, v1.23.8, v1.24.7, v1.25.0, v1.26.0 and gitea.com's live `/swagger.v1.json` (<https://github.com/go-gitea/gitea/tree/main/templates/swagger>)
- Forgejo swagger specs at release tags v7.0.0, v11.0.0, v12.0.0, v14.0.0 and codeberg.org's live `/swagger.v1.json` (<https://codeberg.org/forgejo/forgejo>)
- <https://docs.gitea.com/api/1.24/>

Specs show what each server documents. They do not prove runtime behavior.
