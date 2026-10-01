# Buildkite

How kinhin talks to Buildkite, and how that compares with Buildkite's current REST API docs.

[← Back to README](../../README.md) · [Forge reference index](README.md) · [Setup guide](../forges.md)

## Overview

| | |
|---|---|
| Forge id | `buildkite` |
| Hosting | Buildkite SaaS only. The base is fixed at `https://api.buildkite.com`; `instance` is unused. |
| Scope | `org/cluster` (organization slug and cluster name or UUID). |
| Source | `Sources/KinhinKit/Forges/BuildkiteClient.swift`, `BuildkiteForge.swift`, `BuildkiteModels.swift` |
| Live-tested | No (stubbed HTTP). |

## Auth

`Authorization: Bearer <token>` (`BuildkiteClient.swift:238`). The token is a REST API access token. `BuildkiteModels.swift:41` requires these scopes and `BuildkiteClient.swift:42` checks them against `GET /v2/access-token`:

`read_agents`, `write_agents`, `read_builds`, `read_clusters`, `write_clusters`

Buildkite's docs agree for each call kinhin makes: list agents `read_agents`, stop agent `write_agents`, clusters read `read_clusters`, cluster writes `write_clusters`, builds `read_builds`. Stopping an agent can also be done by a user token with the "Stop Agents" permission.

## API version and base URL

| | We send | Documented (verified 2026-10-01) |
|---|---|---|
| Base | `https://api.buildkite.com` + `/v2/...` | REST API v2 |
| Version header | None | None; the version is in the path. |

## Endpoints used

| Method | Path | Purpose | Code |
|---|---|---|---|
| GET | `/v2/access-token` | Verify the token's scopes | `BuildkiteClient.swift:32` |
| GET | `/v2/organizations` | Organization picker | `BuildkiteClient.swift:79` |
| GET | `/v2/organizations/{org}/clusters` | Resolve the cluster (UUID or case-insensitive name) | `BuildkiteClient.swift:50` |
| GET | `/v2/organizations/{org}/clusters/{id}/queues` | Check the agent queue exists | `BuildkiteClient.swift:72` |
| GET | `/v2/organizations/{org}/clusters/{id}/tokens` | List agent tokens | `BuildkiteClient.swift:96` |
| POST | `/v2/organizations/{org}/clusters/{id}/tokens` | Create the agent token (`{description}`) | `BuildkiteClient.swift:103` |
| DELETE | `/v2/organizations/{org}/clusters/{id}/tokens/{tid}` | Revoke a previous kinhin token | `BuildkiteClient.swift:112` |
| GET | `/v2/organizations/{org}/agents` | List connected agents | `BuildkiteClient.swift:119` |
| PUT | `/v2/organizations/{org}/agents/{id}/stop` | Stop an agent (`{force: true}`) | `BuildkiteClient.swift:127` |
| GET | `/v2/organizations/{org}/builds?state[]=scheduled&state[]=running&state[]=failing` | Demand and running jobs | `BuildkiteClient.swift:139` |

## Registration flow

- Registration mode `sharedLongLived`, exit semantics `deregisters` (`BuildkiteForge.swift:24-25`).
- `BuildkiteForge.make` verifies scopes, resolves the cluster, revokes any earlier token whose description is `kinhin: <account>`, and creates a fresh agent token. The token value is shown only once.
- Agents register at `https://agent.buildkite.com/v3` and run `buildkite-agent start --name --tags --disconnect-after-job` (`RunnerBootstrap+Buildkite.swift:73`).

## Demand and label matching

- Labels are agent tags in `key=value` form. Default: `["queue=kinhin"]`.
- `tags(_:satisfy:)` (`BuildkiteForge.swift:~125`) requires every `agent_query_rule` to match a same-key tag, with `*` as a glob. A job with no `queue` rule is treated as `queue=default`.
- Jobs from another cluster (`cluster_id`) are excluded. Only `script` jobs count.
- Queued means job state `scheduled`. Running means `assigned`, `accepted` or `running` with an agent name.

## Pagination, rate limits, retries

- `per_page=100` and the RFC 8288 `Link: rel="next"` header, up to 20 pages (`BuildkiteClient.swift:17,164-193`).
- A `next` link is followed only over https to the API host; anything else throws `untrustedPageLink` (`BuildkiteClient.swift:175`).
- `withTransientRetry` on network errors, 429 and 5xx. No rate-limit header handling.

## Self-hosted notes and minimum versions

Buildkite has no self-hosted API. The agents run on your machines but the control plane is Buildkite's. There is no instance version to pick.

## Version sensitivity

None for the server. The REST API is a single v2. The `buildkite-agent` binary version is separate (see `Images/RunnerVersions.swift`).

## Audit findings

1. **All calls match the documented endpoints and scopes.** No mismatches found.
2. **Agent list is organization-wide.** `GET …/agents` is documented as organization-level, not cluster-scoped. The docs list a `cluster_queue_id` filter. The client lists every agent in the organization and filters afterward; passing `cluster_queue_id` would shrink the response on busy organizations.
3. **Stop only works on connected agents** (documented). `BuildkiteClient.swift:127` treats a 400 as "already gone", which fits that rule.
4. **Builds can be wide.** The docs offer `exclude_jobs=true` for list calls, but kinhin needs the jobs, so it correctly does not use it.

## Verified

2026-10-01, against:
- <https://buildkite.com/docs/apis/rest-api/agents>
- <https://buildkite.com/docs/apis/rest-api/clusters>
- <https://buildkite.com/docs/apis/rest-api/builds>

The clusters page does not detail the queue and agent-token endpoints; those two rows were not checked against a dedicated page.
