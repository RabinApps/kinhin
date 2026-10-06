# Gitea and Forgejo

How kinhin talks to Gitea Actions and Forgejo Actions, and how that compares with their current API specs. Forgejo is served by the same client (`GiteaClient`); this page notes where the two diverge.

[← Back to README](../../README.md) · [Forge reference index](README.md) · [Setup guide](../forges.md)

## Overview

| | |
|---|---|
| Forge ids | `gitea`, `forgejo` (`GiteaForge.swift:36` only switches the id and display name) |
| Hosting | Self-hosted (Gitea, Forgejo) or hosted (gitea.com, codeberg.org). `instance` is required. |
| Scope | `owner/name` or an org. `actionsBase` is `/api/v1/repos/{scope}/actions` or `/api/v1/orgs/{scope}/actions` (`GiteaClient.swift:32-36`). |
| Source | `Sources/KinhinKit/Forges/GiteaClient.swift`, `GiteaForge.swift`, `GiteaModels.swift` |
| Live-tested | No. Unit tests stub HTTP (`StubProtocol`); `FakeGitea` in `KinhinTestSupport` is pinned to `GiteaForge` by contract tests. |

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
| GET | `{actionsBase}/runners/registration-token` | Mint a registration token; doubles as the permission probe | `GiteaClient.swift:73` (`send` defaults to GET, line 231) |
| GET | `{actionsBase}/runners` | List runners | `GiteaClient.swift:169` |
| DELETE | `{actionsBase}/runners/{id}` | Remove a runner | `GiteaClient.swift:184` |
| GET | `{actionsBase}/tasks?status=waiting&page=1&limit=50` | Queued demand | `GiteaClient.swift:191` |
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
- Runner start: `gitea-runner register --no-interactive --token --labels`, then `gitea-runner daemon` (`RunnerBootstrap+Linux.swift:235-240`). The binary comes from gitea.com releases (`RunnerBootstrap+Verification.swift:62`).

## Demand and label matching

- There is **no label filtering**. Every task the endpoint returns counts as demand.
- A `min_runners` floor (`demandFloor`) applies only when the endpoint answers with zero entries. A failed request keeps the previous scaling state (`GiteaForge.swift:75-90`).
- Running jobs come from running tasks keyed by `runner_name`, falling back to runners with `status == "busy"`.
- Jobs opt in to the pool through `runs-on`; the account `labels` are used at register time.

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
| 1.25 | GET and POST | yes | yes | yes (org, repo, and per run) |
| 1.26 and trunk | **POST only** | yes (adds `disabled`, PATCH) | yes | yes |

### Forgejo

| Release | Reg-token | List and delete runners | `/actions/tasks` | `/actions/runners/jobs?labels=` |
|---|---|---|---|---|
| 7.0 | GET | no | no | no |
| 11.0 | GET | no | yes (`page`, `limit`) | yes |
| 12.0, 14.0 | GET | no | yes | yes |
| trunk (16 dev) | GET | yes (`GET`/`DELETE …/actions/runners`, `POST` to create) | yes (adds `status`) | yes |

## Version sensitivity

| Item | Affects | Detail |
|---|---|---|
| Registration-token method | Gitea ≥ 1.26 | Only POST exists; kinhin sends GET. Forgejo needs GET (no POST). The method must follow the server. |
| Runner list and delete | Gitea < 1.24, Forgejo through at least v14 | Endpoints absent, so `listRunners` and `deleteRunner` get a 404. |
| `/actions/tasks` | Gitea < 1.23, Forgejo < 11 | Endpoint absent. |
| Demand source | Gitea ≥ 1.25, Forgejo ≥ 11 | Better endpoints exist: Gitea `/actions/jobs?status=`, Forgejo `/actions/runners/jobs?labels=`. |
| Runner binary | all | `act_runner` and `gitea-runner` naming. kinhin installs `gitea-runner`; confirm Forgejo's own runner (`forgejo-runner`) is acceptable before relying on the gitea.com download for Forgejo. |

## Audit findings

These are mismatches between the code and the published specs. None were checked against a live Gitea or Forgejo; the existing comment at `GiteaClient.swift:187` says the task queue was "verified on the target instance in the field", so a live check is needed before changing behavior.

1. **Registration-token method breaks on Gitea 1.26+.** The spec for 1.26 lists only `POST …/runners/registration-token`; GET was removed after 1.25. kinhin always sends GET (`GiteaClient.swift:73`). Forgejo is the opposite: GET only. Fix needs a per-forge (or per-version) method.
2. **Task list response shape differs from the spec.** The spec's `ActionTaskResponse` is `{ "total_count", "workflow_runs": [...] }` and `ActionTask` has no `runner_name`. The decoder (`GiteaClient.swift:~296-358`) reads `entries` and `runner_name`. If a real server follows the spec, entries decode as empty, demand falls back to `total_count`, and running-task attribution never matches.
3. **`status` query parameter is not in the spec.** No Gitea release documents `status` on `/actions/tasks` (Forgejo adds it only on trunk). On a server that ignores it, `status=waiting` and `status=running` return the same list, so `total_count` is not a queue length. Gitea's own `/actions/jobs?status=waiting` (1.25+) and Forgejo's `/actions/runners/jobs?labels=` (11+) are the documented ways to read queued jobs, and the Forgejo one also filters by label.
4. **Runner list and delete need newer servers** than the setup guide implies (Gitea 1.24+, Forgejo trunk only).
5. **`GiteaClient.swift:29` has `public var RabinApps: String`**, an `owner` accessor damaged by a global find and replace. It has no callers. Fixed separately from this docs change.
6. **No label filtering and no rate-limit handling** (see above).

## Verified

2026-10-01, against:
- Gitea swagger specs at release tags v1.22.6, v1.23.8, v1.24.7, v1.25.0, v1.26.0 and gitea.com's live `/swagger.v1.json` (<https://github.com/go-gitea/gitea/tree/main/templates/swagger>)
- Forgejo swagger specs at release tags v7.0.0, v11.0.0, v12.0.0, v14.0.0 and codeberg.org's live `/swagger.v1.json` (<https://codeberg.org/forgejo/forgejo>)
- <https://docs.gitea.com/api/1.24/>

Specs show what each server documents. They do not prove runtime behavior.
