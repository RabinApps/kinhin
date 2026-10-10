# Buildkite

How kinhin talks to Buildkite, and how that compares with Buildkite's current REST API docs.

[← Back to README](../../README.md) · [Forge reference index](README.md) · [Setup guide](../forges.md)

## Overview

| | |
|---|---|
| Forge id | `buildkite` |
| Hosting | Buildkite SaaS only. The base is fixed at `https://api.buildkite.com`; `instance` is unused. |
| Scope | `org/cluster` (organization slug and cluster name or UUID). |
| Source | `Sources/KinhinKit/Forges/Buildkit/BuildkiteClient.swift`, `BuildkiteForge.swift`, `BuildkiteModels.swift`; agent start-up in `Sources/KinhinKit/Images/RunnerBootstrap/RunnerBootstrap+Buildkite.swift` |
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
| GET | `/v2/organizations/{org}/clusters/{id}/queues` | Check the agent queue exists (when the forge is built) | `BuildkiteClient.swift:72` |
| GET | `/v2/organizations/{org}/clusters/{id}/tokens` | List agent tokens | `BuildkiteClient.swift:96` |
| POST | `/v2/organizations/{org}/clusters/{id}/tokens` | Create the agent token (`{description}`) | `BuildkiteClient.swift:103` |
| DELETE | `/v2/organizations/{org}/clusters/{id}/tokens/{tid}` | Revoke a previous kinhin token | `BuildkiteClient.swift:112` |
| GET | `/v2/organizations/{org}/agents` | List connected agents | `BuildkiteClient.swift:119` |
| PUT | `/v2/organizations/{org}/agents/{id}/stop` | Stop an agent (`{force: true}`) | `BuildkiteClient.swift:127` |
| GET | `/v2/organizations/{org}/builds?state[]=scheduled&state[]=running&state[]=failing` | Demand and running jobs | `BuildkiteClient.swift:139` |

## Pipeline view

`GET /organizations/{org}/builds?state[]=scheduled,running,failing` returns each build with its `jobs[]`. The build
whose running script job has this agent's name is shown, with every script job (waiter, block and trigger steps left
out) and the build's `web_url`. Buildkite exposes jobs, not steps within a job, so the view is job-level.

Output is `GET /organizations/{org}/pipelines/{slug}/builds/{n}/jobs/{id}/log`, which needs the token's `read_build_logs` scope.

## Registration flow

- Registration mode `sharedLongLived`, exit semantics `deregisters` (`BuildkiteForge.swift:24-25`).
- `BuildkiteForge.make` verifies scopes, resolves the cluster, checks that the `queue=` tag names a queue of the cluster (`default` when there is none; the error lists the queues that exist), revokes tokens left by dead processes of this account on this host, and creates a fresh agent token. The token value is shown only once. Listing queues is a clusters read, so it needs the `read_clusters` scope kinhin already requires.
- The token description is `kinhin: <account> @ <host>/<pid>`, so a second engine or host never revokes another's token. Tokens in the older `kinhin: <account>` form are left alone: **revoke them once by hand** in the cluster's agent tokens.
- The agent start script waits 5 s and, when an agent has already exited non-zero (bad token, unknown queue), fails registration with the tail of that agent's `agent.log` and stops the others.
- Pool runtime markers travel as a `kinhin-runtime=<x>` tag: `kinhin-docker`, `kinhin-container` and `kinhin-host` become `kinhin-runtime=docker`, `=container` and `=host`, the only form an agent query rule can target. A job's `kinhin-runtime=docker` rule is translated back to the `kinhin-docker` marker for routing.
- The agent archive is extracted whole and the script asserts `./buildkite-agent` exists, whichever member name the tarball uses; the SHA256SUMS lookup strips `*` and `./` prefixes.
- Agents register at `https://agent.buildkite.com/v3` and run `buildkite-agent start --name --tags --disconnect-after-job` (`RunnerBootstrap+Buildkite.swift:73`).

## Demand and label matching

- Labels are agent tags in `key=value` form. Default: `["queue=kinhin"]`.
- `tags(_:satisfy:)` (`BuildkiteForge.swift:~125`) requires every `agent_query_rule` to match a same-key tag, with `*` as a glob. A job with no `queue` rule is treated as `queue=default`.
- A `kinhin-runtime` rule is the pool's to satisfy (the router picks the pool), so it is ignored when matching the account's labels.
- Jobs from another cluster (`cluster_id`) are excluded. Only `script` jobs count.
- Queued and running jobs and the pipeline view share one cached builds read per interval.
- Queued means job state `scheduled`. Running means `assigned`, `accepted` or `running` with an agent name.

## Pagination, rate limits, retries

- `per_page=100` and the RFC 8288 `Link: rel="next"` header, up to 20 pages (`BuildkiteClient.swift:17,164-193`).
- A `next` link is followed only over https to the API host; anything else throws `untrustedPageLink` (`BuildkiteClient.swift:175`).
- `withTransientRetry` on network errors, 429 and 5xx. No rate-limit header handling.

## Self-hosted notes and minimum versions

Buildkite has no self-hosted API. The agents run on your machines but the control plane is Buildkite's. There is no instance version to pick.

## Version sensitivity

None for the server. The REST API is a single v2. The `buildkite-agent` binary version is separate (see `Images/RunnerVersions.swift`).

## Audit findings (live-run lessons, 2026-10-09)

Found by reading the code against what the live runs of other forges taught. These fixes were **made by code reading and unit tests with fakes only; none has been run against Buildkite.**

What was wrong, and what changed:

- **Agent failures were invisible.** The start script backgrounded each agent and reported success; a bad token or queue looked like a started instance. It now fails with the agent log.
- **Runtime markers meant nothing.** An agent tag has to be `key=value`, so `kinhin-docker` on a pool never reached a job's agent query rules. Markers are now carried as `kinhin-runtime=<x>`.
- **Archive extraction** named a member (`./buildkite-agent`) the release tarball may not use; the whole archive is extracted and checked.
- **The SHA256SUMS lookup** missed entries written as `*name` or `./name`; the prefix is stripped.
- **Token ownership.** Every build revoked every `kinhin: <account>` token, so a second engine or host would revoke the first's. Descriptions now name host and process.
- **A mistyped queue** silently left every job waiting; it is now rejected when the forge is built.
- **The build list was read separately** for demand and for the pipeline view; both use one cached read.

Still to verify live:

- That the agent accepts `kinhin-runtime=docker` in `--tags` and that a job's `agent_query_rules` entry arrives as `kinhin-runtime=docker`.
- That the queues endpoint lists the `default` queue under the key `default` and works with the token's scopes.
- That a real release archive extracts to `./buildkite-agent` and that `SHA256SUMS` entries match the lookup for every asset name.
- That host name and pid in a token description round-trip through the API, and that the one-time manual revoke of legacy `kinhin: <account>` tokens is enough.
- That an agent that fails to register exits non-zero within the 5 s settle window.

### Earlier findings (2026-10-01)


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
