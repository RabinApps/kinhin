# GitLab

How kinhin talks to GitLab CI, and how that compares with GitLab's current REST API docs.

[← Back to README](../../README.md) · [Forge reference index](README.md) · [Setup guide](../forges.md)

## Overview

| | |
|---|---|
| Forge id | `gitlab` |
| Hosting | gitlab.com (default) or self-managed. `instance` is optional (`GitLabModels.swift:10`). |
| Scope | A project path or a group path. Paths nest (`group/sub/project`) and are percent-encoded with `%2F`. The client resolves `GET /projects/{enc}` and falls back to `GET /groups/{enc}`. |
| Source | `Sources/KinhinKit/Forges/Gitlab/GitLabClient.swift`, `GitLabForge.swift`, `GitLabModels.swift`; config check in `Sources/KinhinKit/Config/ConfigLoader/ConfigLoader+Ephemeral.swift` |
| Live-tested | GitLab CE 18.4 on every runtime, by the [end-to-end suite](../e2e-testing.md). |

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
| GET | `/groups/{id}/projects?include_subgroups=true&archived=false&with_shared=false&simple=true&order_by=last_activity_at&last_activity_after=…` | Projects to poll for a group scope | `GitLabClient.swift:185` |
| GET | `/projects?membership=true&min_access_level=40`, `/groups?min_access_level=50` | Pickers | `GitLabClient.swift:67,76` |
| GET | `/personal_access_tokens/self` | Token scope check | `GitLabClient.swift:203` |
| GET | `/version` | Minimum version check | `GitLabClient.swift:211` |

The `POST /user/runners` body is `{description, tag_list, run_untagged: false, runner_type: project_type|group_type, project_id|group_id}`. GitLab's docs list the same fields and add `instance_type`.

## Pipeline view

The running job (`/projects/{id}/jobs?scope[]=running`, matched by runner description) names its pipeline; the view
then reads `GET /projects/{id}/pipelines/{pid}` and `/pipelines/{pid}/jobs`. GitLab's API has no step list below a job,
so the view is job-level.

Output is the job trace, `GET /projects/{id}/jobs/{job}/trace` (live while the job runs), cleaned of ANSI and section markers.

## Registration flow

- Registration mode `perRunner`: one runner is created per VM runner name (`GitLabForge.swift:68-77`). Exit semantics `deregisters`.
- `tag_list` is the pool's labels (fleet labels plus the runtime marker, minus what the pool's platform cannot serve). When the engine names no pool it falls back to the account's labels. The two are not unioned, because that re-added labels routing had removed (`macos` on a Linux VM).
- `vm.ephemeral: false` is rejected at config load for a GitLab account: the runner takes one job (`run-single --max-builds 1`) and deletes itself, so a persistent VM would sit idle after its first job.
- Each runner runs `gitlab-runner run-single --description ... --executor shell` and removes itself afterwards (`RunnerBootstrap+GitLab.swift:68`).
- `mintRegistrationToken` throws: kinhin never uses GitLab's legacy shared registration tokens.
- The authentication token is returned once. GitLab's docs: it "cannot be retrieved again".

## Demand and label matching

- GitLab has no group-wide job queue. For a group, the client reads at most 50 recently active projects per poll, 8 at a time. The project list is cached for 300 s, excludes projects merely shared into the group (`with_shared=false`) and skips projects with no activity for 24 h. A project that fails to read (403, 404, 5xx) is skipped with a warning so it cannot hide the others' demand; when every project fails the first error is thrown, and a 401 always is.
- A single-project scope has nothing to fall back to: every read failure surfaces as an error rather than an empty queue.
- `isOurs` requires `job.tag_list ⊆ pool labels` (case-insensitive), where the pool labels are the union of the labels every pool and named image registers runners with. An untagged job never matches. This is the opposite direction from GitHub's rule (`labels ⊆ job.labels`). The reason: GitLab hands a job to a runner whose tags are a superset of the job's tags, so a job is servable exactly when its tags are a subset of what some pool advertises, whereas GitHub's `runs-on:` is matched against the single set of labels kinhin registers.
- Jobs of merge-request pipelines (`merge_request_event` source, or a `refs/merge-requests/` ref) are flagged `isFork`, because that ref can carry a fork's code: no repository file and no cache trust.
- The pipeline view reuses the poll's running-jobs read while it is under 10 s old instead of fanning out again. The runner list is dropped before "gone" or "idle" is decided.

## Pagination, rate limits, retries

- Offset pagination, following `X-Next-Page`, `per_page=100`, up to 50 pages (`GitLabClient.swift:230-245`). GitLab documents `per_page` max 100.
- `withTransientRetry` on network errors, 429 and 5xx. `RateLimit-*` and `X-RateLimit-*` headers are parsed and kept as the account's rate-limit state; self-managed instances often send none.

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

## Open notes

1. **Pagination mode.** GitLab recommends keyset pagination for large job lists. Offset pagination works but gets
   slower on large collections; with `scope[]=pending|running` the result sets are small, so this is low risk.
2. **`/jobs` has no group endpoint**, so large groups depend on the 50-project and 24-hour limits. This is a documented
   API gap.
3. **The 16.0 floor** comes from the code; GitLab's release notes do not name the release that introduced
   `POST /user/runners`.
4. **gitlab.com** uses the same API but is not part of the tested launch set; self-managed GitLab CE is.

## Verified

2026-10-01, against:
- <https://docs.gitlab.com/api/users/> (create runner)
- <https://docs.gitlab.com/api/runners/>
- <https://docs.gitlab.com/api/jobs/>
- <https://docs.gitlab.com/api/rest/>
