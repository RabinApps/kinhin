# Bitbucket Cloud

How kinhin talks to Bitbucket Pipelines runners, and how that compares with Atlassian's published API spec.

[← Back to README](../../README.md) · [Forge reference index](README.md) · [Setup guide](../forges.md)

## Overview

| | |
|---|---|
| Forge id | `bitbucket` |
| Hosting | Bitbucket Cloud only. The base is fixed at `https://api.bitbucket.org`; `instance` is unused. Bitbucket Data Center is not supported (not researched). |
| Scope | A workspace, or `workspace/repo`. |
| Source | `Sources/KinhinKit/Forges/BitbucketClient.swift`, `BitbucketForge.swift`, `BitbucketModels.swift` |
| Live-tested | No (stubbed HTTP). |

## Auth

`Authorization: Bearer <token>` with a workspace or repository access token (`BitbucketClient.swift:248`). App passwords lack the runner scopes (`TokenRequirements.bitbucket`).

The published spec marks runner reads with the OAuth scope `runner`, runner writes (create, update, delete) with `runner:write`, and pipeline steps with `pipeline`. These match the scopes the token guidance asks for.

## API version and base URL

| | We send | Documented (verified 2026-10-01) |
|---|---|---|
| Base | `https://api.bitbucket.org/2.0/...` | REST API 2.0 |
| Version header | None | None; the version is in the path. |

## Endpoints used

| Method | Path | Purpose | Code |
|---|---|---|---|
| GET | `/2.0/workspaces/{w}` | Validate workspace, get its UUID | `BitbucketClient.swift:58,149` |
| GET | `/2.0/repositories/{w}/{slug}` | Validate repository, get its UUID | `BitbucketClient.swift:61` |
| GET | `/2.0/workspaces/{w}/pipelines-config/runners` or `/2.0/repositories/{w}/{slug}/pipelines-config/runners` | List runners | `scope.runnerPath` |
| POST | same path | Create a runner (`{name, labels}`); returns OAuth `client_id` and `secret` | `BitbucketClient.swift:83` |
| DELETE | same path + `/{uuid}` | Remove a runner (a 404 is treated as already gone) | `BitbucketClient.swift:95` |
| GET | `/2.0/repositories/{repo}/pipelines/?sort=-created_on` | Recent pipelines (one page per repository) | `BitbucketClient.swift:112,114` |
| GET | `/2.0/repositories/{repo}/pipelines/{uuid}/steps` | Steps of a pipeline | `BitbucketClient.swift:122` |
| GET | `/2.0/repositories/{w}?sort=-updated_on` | Active repositories for a workspace scope | `BitbucketClient.swift` |
| GET | `/2.0/repositories/{w}?role=contributor` | Repository picker | `BitbucketClient.swift` |

All six runner operations (list, create, get, update, delete, at workspace and repository level) are in the published spec with the paths above.

## Pipeline view

The active pipeline (`PENDING` or `IN_PROGRESS`, from `/pipelines/?sort=-created_on`) and its `/steps` are shown, each
Bitbucket step as one job with its state and result. Which runner took a step is not public, so every running step is
marked as this VM's, and the API has no list of commands within a step (job-level).

## Registration flow

- Registration mode `perRunner`, exit semantics `idleGrace` (`BitbucketForge.swift:51-52`): the Bitbucket runner has no single-job mode, so it idles out.
- Each runner is created with labels `["self.hosted", "linux.shell" | "macos"] + account labels`.
- The credential bundle `workspaceUUID|repoUUID|runnerUUID|clientId|secret` is stored as the runner token (`BitbucketForge.swift:~118`). The agent starts with `--accountUuid --runnerUuid ...` (`RunnerBootstrap+Bitbucket.swift:136`).

## Demand and label matching

- The public API has no queued-steps endpoint, so demand is derived from steps of `PENDING` or `IN_PROGRESS` pipelines.
- A workspace scope polls at most 20 recently active repositories.
- `isOurs` counts a step when its `runs_on` is empty (the API does not expose it yet) or when `labels ⊆ runsOn`.
- A running step marks every runner busy, because steps do not name their runner.

## Pagination, rate limits, retries

`pagelen=100` and the `next` URL in the response body, up to 20 pages (`BitbucketClient.swift:18,173-177`); some calls take one page only. Next links are checked against a trusted host. `withTransientRetry` on network errors, 429 and 5xx.

## Self-hosted notes and minimum versions

Bitbucket Cloud has no instance version. Bitbucket Data Center is a different API and is out of scope; it was not researched.

## Version sensitivity

None. There is a single 2.0 API.

## Audit findings

1. **Runner endpoints and scopes match the published spec.**
2. **Demand is approximate by design.** The step list does not carry the runner it ran on, and `runs_on` may be empty, so label matching can over-count and "busy" is a guess. That is an API limitation.
3. **Pipelines list is one page per repository**, newest first, so a burst of more than a page of recent pipelines can hide older queued ones. Low risk; recorded for completeness.
4. **Pipeline path has a trailing slash** (`/pipelines/`). The spec lists the collection path without one. Whether the server treats both forms alike was not verified.

## Verified

2026-10-01, against Atlassian's OpenAPI document (<https://dac-static.atlassian.com/cloud/bitbucket/swagger.v3.json>, runners, pipeline steps and their OAuth scopes). The runner HTML reference page could not be read, so field-level request and response bodies (`name`, `labels`, the returned OAuth credentials) were not re-checked.
