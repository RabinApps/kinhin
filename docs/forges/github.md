# GitHub

How kinhin talks to GitHub Actions, and how that compares with GitHub's current REST API docs.

[← Back to README](../../README.md) · [Forge reference index](README.md) · [Setup guide](../forges.md)

## Overview

| | |
|---|---|
| Forge id | `github` |
| Hosting | github.com only. The client hard-codes `https://api.github.com`; GitHub Enterprise Server (GHES) is **not supported** (see [Self-hosted notes](#self-hosted-notes-and-minimum-versions)). |
| Scope | `owner/name` (one repository) or an org name. `actionsBase` is `/repos/{scope}/actions` or `/orgs/{scope}/actions`. |
| `instance` | Unused. |
| Source | `Sources/KinhinKit/Forges/GitHubClient.swift`, `GitHubClient+Runs.swift`, `GitHubForge.swift`, `GitHubModels.swift` |
| Live-tested | Yes. This is the only forge exercised against the real service. |

## Auth

`Authorization: Bearer <PAT>` (`GitHubClient.swift:157`). Both fine-grained and classic personal access tokens work. Permission lists live in `TokenRequirements.github(scope:)`.

| Token | Repository scope | Organization scope |
|---|---|---|
| Fine-grained | Administration: read and write; Actions: read-only; Metadata: read-only | Organization "Self-hosted runners": read and write; repository Actions: read-only on all repositories |
| Classic | `repo` | `admin:org`, `repo` |

GitHub's docs agree: runner endpoints need repository `admin` or organization `admin:org` (plus `repo` for private repositories).

## API version and base URL

| | We send | GitHub documents (verified 2026-10-01) |
|---|---|---|
| Base | `https://api.github.com` | `https://api.github.com`; GHES uses `{protocol}://{hostname}/api/v3` |
| `X-GitHub-Api-Version` | `2022-11-28` (`GitHubClient.swift:160`) | Two supported versions: `2022-11-28` (supported until 2028-03-10) and `2026-03-10` (no end date). An absent header defaults to `2022-11-28`. |
| `Accept` | `application/vnd.github+json` | Same |

GitHub supports each version for 24 months after the next one ships, signals retirement with `Deprecation` and `Sunset` headers, and answers `410 Gone` once a version is retired.

**Diff of the two versions for kinhin's endpoints:** a comparison of the published OpenAPI descriptions (`api.github.com.2022-11-28.json` vs `.2026-03-10.json`) shows the same path set, and every endpoint kinhin calls has an identical definition. The only differences are on `POST /user/repos` and `POST /orgs/repos`, which kinhin does not call. Moving to `2026-03-10` is therefore a no-op for kinhin today.

## Endpoints used

| Method | Path | Purpose | Code |
|---|---|---|---|
| POST | `{actionsBase}/runners/registration-token` | Mint a runner registration token (1 h lifetime) | `GitHubClient.swift:243` |
| GET | `{actionsBase}/runners?per_page=100&page=N` | List runners | `GitHubClient.swift:323` |
| DELETE | `{actionsBase}/runners/{id}` | Remove a runner | `GitHubClient.swift:344` |
| GET | `/repos/{repo}/actions/runs?status=queued\|in_progress&per_page=100&page=N` | Demand and running jobs (repo scope; org scope per repository) | `GitHubClient+Runs.swift` |
| GET | `/orgs/{org}/actions/runs` | Not used (undocumented) | none |
| GET | `/repos/{repo}/actions/runs/{id}/jobs?per_page=100` (org mode: `{actionsBase}/runs/{id}/jobs`) | Job labels for matching | `GitHubClient+Runs.swift:139-141` |
| GET | `/user/repos?affiliation=owner,collaborator,organization_member` | Repository picker | `GitHubClient.swift:270` |
| GET | `/orgs/{org}/repos`, `/users/{owner}/repos` | Repository picker, org and user | `GitHubClient.swift:272-274` |

## Scale sets (future direction)

GitHub's supported autoscaling path is runner scale sets plus JIT runner configuration (see [`actions/scaleset`](https://github.com/actions/scaleset)). The scale-set message API is Public Preview and, like the endpoint removed above, is not in any published OpenAPI description. kinhin keeps polling documented per-repository endpoints until the message API is documented. JIT stays out of scope (audit finding 2 is unchanged).

### Scale set mode in kinhin

kinhin has an opt-in scale-set mode for GitHub accounts. It is not the default and does not replace the documented REST
poll. When a GitHub account has `scale_set:` set, kinhin uses the Actions-service message path for demand instead of
polling workflow runs, and registers spawned runners with JIT configs.

Implementation notes:

- Admin exchange goes through `POST /actions/runner-registration` and returns an Actions-service URL plus a JWT.
- Scale-set and runner-group state is managed under `api-version=6.0-preview`.
- Demand comes from a long-poll message session plus scale-set statistics, not from `GET .../workflow-runs`.
- Runner registration uses `POST .../generatejitconfig` and the in-VM `config.sh --jitconfig` path.
- The listener service, client, and JIT adapter live in `Sources/KinhinKit/Fleet/` and `Sources/KinhinKit/Forges/`
  (see [architecture](https://github.com/RabinApps/kinhin/blob/main/docs/architecture.md) for the layout).

Caveat: because the message API is still preview and not in GitHub's published OpenAPI descriptions, the endpoint set
and versioning should be re-verified when GitHub updates the API. GitHub Enterprise Server is not supported in this mode.

### Scale-set troubleshooting (kinhin side)

For the error signatures that show up in kinhin logs and how to read them, see [Troubleshooting scale sets](scaling.md#troubleshooting-scale-sets) in *How scaling works*. The two most common are:

- `cd: /Users/admin/actions-runner-N: No such file or directory` (`bash: line …: cd: …: No such file or directory` in
  the in-VM script) — a per-runner directory is missing on the image; usually a `runners_per_vm` bake/fleet mismatch.
  Scale-set mode does **not** use a separate image; the same baked image that works for classic mode also boots scale-set
  VMs. See the density-mismatch section.
- `could not pin the guest's SSH host key … connecting without host key verification` — a boot/SSH-agent reachability issue,
  not a registration-material issue. Establish that one VM can boot and register in classic mode before scaling it.

If the listener can't refresh statistics or the session drops, the engine keeps the last known snapshot briefly; if that
keeps failing, re-check the account token and scopes (organization self-hosted-runner permissions) and confirm the account is
github.com.

## Pipeline view

The app's live pipeline view reads `GET /repos/{repo}/actions/runs?status=in_progress` and each run's
`/actions/runs/{id}/jobs`. The job payload already carries `steps[]` (name, status, conclusion, number, timestamps) and
`html_url`, so it costs no request beyond the running-attribution poll. The runner's job is found by `runner_name`.

Step output is sliced from `GET /repos/{repo}/actions/jobs/{id}/logs` (a redirect to a signed URL, fetched without the token) by each line's timestamp and the step start times.

## Registration flow

- Registration mode `sharedShortLived`, exit semantics `deregisters` (`GitHubForge.swift`).
- Token lifetime: about one hour, cached per account by `RegistrationTokenCache` (`Fleet/FleetEngine+Accounts.swift`, `token_ttl` in config).
- The runner starts with `config.sh --url --token --labels --unattended --ephemeral`, then `run.sh` (`Images/RunnerBootstrap/RunnerBootstrap+Linux.swift:184-206`).
- kinhin does **not** use JIT runner configuration. GitHub documents `POST /{orgs|repos}/.../actions/runners/generate-jitconfig` (body: `name`, `runner_group_id`, `labels`), which is present in every API version and in GHES. JIT would remove the shared token from the VM, which is a hardening opportunity (see [Audit findings](#audit-findings)).

## Demand and label matching

- `queuedJobs(matching:)` and `runningJobs(matching:)` count a job only when the fleet's labels are a subset of `job.labels` and `status` is `queued` or `in_progress`.
- A running job maps back to a VM through `runner_name`.
- The client reads workflow *runs* first (`status=queued` and `status=in_progress`), then each run's jobs. It reads at most 50 runs per poll (`maxRunsPerPoll`).

## Pagination, rate limits, retries

- Page-number loops with `per_page=100`, stopping at `total_count`, an empty page (runs, runners) or a short page (repos).
- A conditional-GET (ETag) cache absorbs repeat polls; a `304` is served from cache (`ConditionalGetCache.swift`).
- Rate limits: a `403` with `X-RateLimit-Remaining: 0` throws `rateLimited(resetAt)`; any other `403` is retried as a possible secondary limit; `429` and `5xx` are retried; up to 3 retries, backoff 2^n capped at 8 s.
- GitHub is the only client with its own retry loop instead of `withTransientRetry`.

## Self-hosted notes and minimum versions

- **GHES is not supported.** The base URL is a constant and `AccountConfig.instance` is ignored for GitHub. Supporting GHES means a configurable base (`https://{host}/api/v3`) plus a decision on which API-version header values the target GHES release accepts. The GHES OpenAPI descriptions published by GitHub (`ghes-3.14` and `ghes-3.22` checked) contain the same runner, run and job endpoints kinhin uses.
- The `X-GitHub-Api-Version` values available on a given GHES release were **not verified** here; GitHub's page on API versions says nothing about GHES.

## Version sensitivity

| Item | Varies by | Detail |
|---|---|---|
| `X-GitHub-Api-Version` | github.com | `2022-11-28` and `2026-03-10` are identical for the endpoints kinhin calls. |
| Base path | github.com vs GHES | `/` vs `/api/v3`. |
| `/orgs/{org}/actions/runs` | all | Not used (undocumented). |

## Audit findings

1. **Resolved (2026-10-01): undocumented endpoint.** `GET /orgs/{org}/actions/runs` is absent from the OpenAPI descriptions for both github.com versions and from GHES 3.14 and 3.22. It used to be the classic-token fast path, with a per-repository fallback on 404. kinhin never calls it now: org scope reads each repository's runs via the documented `GET /repos/{repo}/actions/runs`.
2. **JIT config unused** (see Registration flow). Ephemeral runners with a shared registration token are valid, but JIT is GitHub's recommended path for ephemeral runners.
3. **No GHES support.** Hard-coded base URL.
4. **Documented status values are wider than the ones used.** GitHub lists `queued`, `in_progress`, `waiting`, `pending`, `requested` as run statuses. kinhin polls only `queued` and `in_progress`, so a run held in `waiting` (for example on an environment approval) is not counted as demand, which is arguably correct. Recorded here as intent, not a bug.

## Verified

2026-10-01, against:
- <https://docs.github.com/en/rest/about-the-rest-api/api-versions>
- <https://docs.github.com/en/rest/actions/self-hosted-runners>
- <https://docs.github.com/en/rest/actions/workflow-runs>
- OpenAPI descriptions: <https://github.com/github/rest-api-description> (`api.github.com` 2022-11-28 and 2026-03-10, `ghes-3.14`, `ghes-3.22`)
