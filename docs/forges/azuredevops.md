# Azure DevOps

How kinhin talks to Azure Pipelines agent pools, and how that compares with Microsoft's current REST API docs.

[← Back to README](../../README.md) · [Forge reference index](README.md) · [Setup guide](../forges.md)

## Overview

| | |
|---|---|
| Forge id | `azuredevops` |
| Hosting | Azure DevOps Services (`https://dev.azure.com/{org}`) or Azure DevOps Server (self-hosted). `instance` is required and is the organization (or collection) URL. |
| Scope | An agent pool name. |
| Source | `Sources/KinhinKit/Forges/AzureDevOps/AzureDevOpsClient.swift`, `AzureDevOpsForge.swift`, `AzureDevOpsModels.swift`; agent start-up in `Sources/KinhinKit/Images/RunnerBootstrap/RunnerBootstrap+AzureDevOps.swift` |
| Live-tested | No (stubbed HTTP). |

## Auth

HTTP Basic with an empty user name and the PAT as the password: `Authorization: Basic base64(":" + PAT)` (`AzureDevOpsClient.swift:136`). A rejected PAT can come back as a `203`, an HTML sign-in page, or a redirect to the sign-in host (which the session refuses to follow, so the 3xx itself arrives); the client treats all three as unauthorized (`AzureDevOpsClient.rejectSignInPage`). `TokenRequirements.azureDevOps` lists the permission (Agent Pools read and manage).

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
- The registration credential **is the PAT itself**: `mintRegistrationToken` returns `credentials.token`. The agent is configured **in the foreground** with `config.sh --unattended --url --auth pat --pool --agent`, the token passed through `VSTS_AGENT_INPUT_TOKEN` for that command only, so a failed registration fails the script with the tail of `agent.log`. Registration is sequential, one runner after another. The registered agent then runs in the background (`run.sh --once` when the instance is ephemeral, plain `run.sh` when `vm.ephemeral` is false) and finally `config.sh remove`. The PAT is no longer written to a `.pat` file: it reaches the background shell through a pipe, in an unexported variable. It is still copied into every runner VM, which `TokenRequirements` already warns about.

## Demand and label matching

- `demands(_:include:)` requires a request's demands to include every label. A bare `name` matches any demand with that name; `name=value` matches `name -equals value`, case-insensitive.
- Labels are exported to the agent as capabilities (`name=true` or `name=value`). The pool's labels join the account's (the account wins on a name clash), and every name is made a valid environment variable name, so `kinhin-docker` becomes `kinhin_docker=true`. A job on a docker pool must therefore demand both `kinhin` and `kinhin_docker`. A `kinhin_docker` demand is translated back to the `kinhin-docker` marker for routing.
- Queued means `assignTime == nil` with no result **and no reserved agent**: a request already reserved for an agent is not demand for another. A request demanding `Agent.OS -equals` something other than Darwin or Linux (Windows) is not demand either, since no guest could take it.
- Running means `assignTime != nil` with no result and a reserved agent.
- An agent seen online that stays offline for 60 s is reported gone and its record deleted, so a failed `config.sh remove` in the guest no longer keeps the instance's exit watch waiting.

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

## Audit findings (live-run lessons, 2026-10-09)

Found by reading the code against what the live runs of other forges taught. These fixes were **made by code reading and unit tests with fakes only; none has been run against Azure DevOps.**

What was wrong, and what changed:

- **Registration failures vanished.** `config.sh` ran inside a background shell, so a bad PAT or pool name looked like a started instance. It now runs in the foreground and fails with the log tail.
- **The PAT touched disk** (a `.pat` file removed after reading). It is now piped to the background shell.
- **Pool labels and runtime markers never became capabilities**, and `kinhin-docker` is not a valid variable name. Labels are sanitised and the pool's join the account's.
- **Linux guests**: the agent's `installdependencies.sh` refuses to run unprivileged; it now runs under `sudo`, followed by an `Agent.Listener --version` smoke test.
- **`ephemeral: false` was ignored**; the agent always ran `--once`. It is now honoured.
- **Offline agents lingered** when `config.sh remove` failed; they are reaped after 60 s.
- **A sign-in redirect** was not classified as unauthorized; it is now.
- **Reserved and unsatisfiable requests counted as demand**, spawning runners that could not take them.

Still to verify live:

- **Highest-impact risk: an empty pool plus a `demands:` job may fail fast rather than queue.** Azure may reject a request whose demands no agent in the pool satisfies instead of leaving it waiting, so kinhin would never see demand to scale up from. If so, the pool needs a placeholder offline agent that advertises the capabilities, or `min_runners >= 1`. Not verified.
- That an exported `kinhin_docker=true` environment variable is picked up as a capability by the agent, and that the demand arrives as `kinhin_docker`.
- That `installdependencies.sh` under `sudo` succeeds on the Tart Linux image and that `Agent.Listener --version` runs there.
- That the 60 s offline grace never reaps an agent that is merely between jobs.
- That a request carries `reservedAgent` before `assignTime`, as the queued rule assumes.
- That a redirect really is how an expired PAT presents on Azure DevOps Services and Server.
- That sequential registration of several runners in one VM is fast enough.

### Earlier findings (2026-10-01)


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
