# Azure DevOps

How kinhin talks to Azure Pipelines agent pools, and how that compares with Microsoft's current REST API docs.

[← Back to README](../../README.md) · [Forge reference index](README.md) · [Setup guide](../forges.md)

## Overview

| | |
|---|---|
| Forge id | `azuredevops` |
| Hosting | Azure DevOps Services (`https://dev.azure.com/{org}`) or Azure DevOps Server (self-hosted). `instance` is required and is the organization (or collection) URL. |
| Scope | An agent pool name. |
| Source | `Sources/KinhinKit/Forges/AzureDevOpsClient.swift`, `AzureDevOpsForge.swift`, `AzureDevOpsModels.swift` |
| Live-tested | No (stubbed HTTP). |

## Auth

HTTP Basic with an empty user name and the PAT as the password: `Authorization: Basic base64(":" + PAT)` (`AzureDevOpsClient.swift:136`). A rejected PAT can come back as a `203` or an HTML sign-in page, and the client treats both as unauthorized (`AzureDevOpsClient.swift:143-147`). `TokenRequirements.azureDevOps` lists the permission (Agent Pools read and manage).

Microsoft's OAuth scopes line up: `vso.agentpools` for reading pools, agents and job state, `vso.agentpools_manage` for deleting agents.

## API version and base URL

| | We send | Documented (verified 2026-10-01) |
|---|---|---|
| Version | `api-version=7.0` on every URL (`AzureDevOpsClient.swift:15,112`) | The version **must** be sent on every request. |
| Current | n/a | 7.1 is the stable reference version in the docs; 7.2 reference pages also exist. |

Which products accept which version (Microsoft's REST API versioning page):

| Product | Highest REST version |
|---|---|
| Azure DevOps Services | 7.0+ (docs also cover 7.1 and 7.2) |
| Azure DevOps Server 2022 | 7.0 |
| Azure DevOps Server 2020 | **6.0** |
| Azure DevOps Server 2019 | 5.0 |

Per-operation reference pages for Azure DevOps Server exist for 6.0, 7.0 and 7.1 (`azure-devops-server-rest-7.1`), so a newer Server release than 2022 ships API 7.1. Which Server release that is was not stated on the pages fetched.

## Endpoints used

| Method | Path | Purpose | Code |
|---|---|---|---|
| GET | `/_apis/distributedtask/pools?poolName=X&actionFilter=manage` | Resolve the pool and check manage rights; falls back to no `actionFilter` to tell "not found" from "cannot manage" | `AzureDevOpsClient.swift:33,40` |
| GET | `/_apis/distributedtask/pools?actionFilter=manage` | Pool picker | `AzureDevOpsClient.swift:51` |
| GET | `/_apis/distributedtask/pools/{id}/agents?includeAssignedRequest=true` | List agents | `AzureDevOpsClient.swift:62` |
| DELETE | `/_apis/distributedtask/pools/{id}/agents/{aid}` | Remove an agent (a 404 is treated as already gone) | `AzureDevOpsClient.swift:70` |
| GET | `/_apis/distributedtask/pools/{id}/jobrequests?completedRequestCount=0` | Demand and running jobs | `AzureDevOpsClient.swift:82` |

## Pipeline view

The running job request names its build (`owner.id`), project (`scopeId`) and timeline job (`jobId`). The view reads
`GET /{project}/_apis/build/builds/{id}/timeline` (Job records are the jobs, their Task children the steps) and
`/builds/{id}` for the title, branch and link. This request-to-build link is undocumented (like the job requests
endpoint itself); a request without it shows no detail.

Output is `GET /{project}/_apis/build/builds/{id}/logs/{logId}`, with the log id taken from the timeline record of the task (or job).

## Registration flow

- Registration mode `sharedLongLived`, exit semantics `deregisters` (`AzureDevOpsForge.swift:28-29`).
- The registration credential **is the PAT itself**: `mintRegistrationToken` returns `credentials.token`. The agent is configured with `config.sh --unattended --url --auth pat --pool --agent`, the token passed through `VSTS_AGENT_INPUT_TOKEN`, then `run.sh --once`, then `config.sh remove` (`RunnerBootstrap+AzureDevOps.swift:112-115`). The PAT is therefore copied into every runner VM, which `TokenRequirements` already warns about.

## Demand and label matching

- `demands(_:include:)` requires a request's demands to include every label. A bare `name` matches any demand with that name; `name=value` matches `name -equals value`, case-insensitive.
- Labels are exported to the agent as capabilities (`name=true` or `name=value`).
- Queued means `assignTime == nil` with no result. Running means `assignTime != nil` with no result and a reserved agent.

## Pagination, rate limits, retries

No pagination: every list is a single `{value: [...]}` read. `withTransientRetry` on network errors, 429 and 5xx. No rate-limit header handling.

## Self-hosted notes and minimum versions

- For Azure DevOps Server, `instance` is the organization or collection URL the user supplies; the exact URL shape for Server was not verified here.
- `api-version=7.0` works on Services and Server 2022 only. Server 2020 and earlier reject it.

## Version sensitivity

| Item | Detail |
|---|---|
| `api-version` | 7.0 fits Services and Server 2022. Server 2020 tops out at 6.0; Server 2019 at 5.0. Newer Server releases offer 7.1. |
| Endpoints used | The pool and agent operations exist in the 5.1, 6.0, 6.1, 7.0 and 7.1 references, so lowering `api-version` for older Server is plausible. Not tested. |
| Preview versions | After a release, its `-preview` form is deprecated and can be removed after 12 weeks. kinhin uses only stable versions. |

## Audit findings

1. **`jobrequests` is not in the REST reference.** The docs list agent, pool and agent-cloud operations, and a "Requests - List" operation, but that one lives under `agentclouds/{id}/requests`. The `pools/{id}/jobrequests` path that kinhin uses for demand was not found on the pages checked. It was not verified against a live organization here; as an undocumented path it may change without a version bump.
2. **Pinned to 7.0.** Fine for Services and Server 2022, but it excludes Server 2020 and earlier, and it trails the documented 7.1. This is the clearest candidate for a version picker.
3. **No pagination.** kinhin reads each list once. The pages fetched did not say whether pool and agent lists are paged, so large pools are unverified.
4. **PAT reuse.** The same PAT that manages the pool is on every VM (documented design limit, not a code bug).

## Verified

2026-10-01, against:
- <https://learn.microsoft.com/en-us/azure/devops/integrate/concepts/rest-api-versioning>
- <https://learn.microsoft.com/en-us/rest/api/azure/devops/distributedtask/pools/get-agent-pools?view=azure-devops-rest-7.1>
- <https://learn.microsoft.com/en-us/rest/api/azure/devops/distributedtask/agents?view=azure-devops-rest-7.1>
- <https://learn.microsoft.com/en-us/rest/api/azure/devops/distributedtask/agents/delete?view=azure-devops-rest-7.1>
- <https://learn.microsoft.com/en-us/rest/api/azure/devops/distributedtask/requests/list?view=azure-devops-rest-7.1>
