# Azure DevOps

How kinhin talks to Azure Pipelines agent pools, and how that compares with Microsoft's current REST API docs.

[← Back to README](../../README.md) · [Forge reference index](README.md) · [Setup guide](../forges.md)

> **Experimental.** One user has run kinhin against Azure DevOps Services (beta 2, 2026-10): smoke jobs, two concurrent VMs, scale from zero and automatic cleanup worked. Real application builds, several Macs and Azure DevOps Server are unverified, and the project's own live test lane has not run (see the [roadmap](../beta-roadmap.md)). Read [Empty pools](#empty-pools) before relying on scale-to-zero.

## Overview

| | |
|---|---|
| Forge id | `azuredevops` |
| Hosting | Azure DevOps Services (`https://dev.azure.com/{org}`) or Azure DevOps Server (self-hosted). `instance` is required and is the organization (or collection) URL. |
| Scope | An agent pool name. |
| Source | `Sources/KinhinKit/Forges/AzureDevOps/AzureDevOpsClient.swift`, `AzureDevOpsForge.swift`, `AzureDevOpsModels.swift`; agent start-up in `Sources/KinhinKit/Images/RunnerBootstrap/RunnerBootstrap+AzureDevOps.swift` |
| Status | **Experimental.** Unit-tested, and smoke-tested live by a user on Azure DevOps Services (see the banner above). Not in the project's live-tested lane. |

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

- Registration mode `sharedLongLived`, exit semantics `deregisters` (`AzureDevOpsForge.swift:32-33`).
- The registration credential **is the PAT itself**: `mintRegistrationToken` returns `credentials.token`. The agent is configured **in the foreground** with `config.sh --unattended --url --auth pat --pool --agent`, the token passed through `VSTS_AGENT_INPUT_TOKEN` for that command only, so a failed registration fails the script with the tail of `agent.log`. Registration is sequential, one runner after another. The registered agent then runs in the background (`run.sh --once` when the instance is ephemeral, plain `run.sh` when `vm.ephemeral` is false). The agent does **not** remove itself: an in-guest `config.sh remove` would need the PAT for the whole job, where job code could read it. The script unsets the PAT as soon as `config.sh` returns, and the host deletes the agent's record once it goes offline (below). The PAT still reaches every runner VM for registration, which `TokenRequirements` already warns about.

## Demand and label matching

- `demands(_:include:)` requires a request's demands to include every label. A bare `name` matches any demand with that name; `name=value` matches `name -equals value`, case-insensitive.
- Labels are exported to the agent as capabilities (`name=true` or `name=value`). The pool's labels join the account's (the account wins on a name clash), and every name is made a valid environment variable name, so `kinhin-docker` becomes `kinhin_docker=true`. A job on a docker pool must therefore demand both `kinhin` and `kinhin_docker`. A `kinhin_docker` demand is translated back to the `kinhin-docker` marker for routing.
- Queued means `assignTime == nil` with no result **and no reserved agent**: a request already reserved for an agent is not demand for another. A request demanding `Agent.OS -equals` something other than Darwin or Linux (Windows) is not demand either, since no guest could take it.
- Running means `assignTime != nil` with no result and a reserved agent.
- An agent seen online that then goes offline is reported gone and its record deleted by the host. This is how a finished agent leaves the pool, and the "finished" signal the instance's exit watch waits for. An idle offline agent (its one job done) is reaped after 15 s; one still holding a job (a heartbeat blip) gets 60 s.

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

## Empty pools

Azure queues a job only when some agent in the pool could run it. With no agent registered it fails the run at once, with `No agent found in pool … which satisfies the specified demands: kinhin, Agent.Version -gtVersion 2.144.0`. kinhin therefore never sees queued demand to scale from. (KEDA's Azure Pipelines scaler documents the same behaviour and uses a placeholder agent for it.) Observed live:

- `min_runners: 1` does not avoid it: the pool is briefly empty while an ephemeral agent is replaced, and jobs queued then failed.
- A permanently **offline** placeholder agent record in the pool fixes it. The record must be enabled and carry what the job demands: the account's labels as capabilities (`kinhin` becomes `kinhin=true`; names are letters, digits and `_`) and an `Agent.Version` at least as high as the YAML demand (`Agent.Version -gtVersion 2.144.0` is added by the pipeline, not by you). The user's record was named `azure-queue-anchor-do-not-run`; it never ran an agent process.
- With the placeholder present, jobs queued without a `reservedAgent`, so kinhin counted them as demand and scaled from zero. kinhin does not reap it: an agent is only reaped after it was seen online (`AgentPresence`), and the placeholder never is.

How the record was created is not recorded in the report. One approach, not verified by the project: register a real agent in the pool with `config.sh` under a name that is not a kinhin instance name, never start it, then add any missing user capabilities in **Project settings → Agent pools → the agent → Capabilities**. Keep these rules:

- Use it only in the pool kinhin serves, and never point kinhin at a pool with other self-hosted agents.
- Do not name it like a kinhin instance (`<prefix><digits>-<hex>`), which the orphan sweep removes.
- Re-test it after a kinhin or agent upgrade and after changing labels: a changed label needs a matching capability on the record.
- This is a user-verified workaround, not something Azure guarantees. kinhin warns at start-up when no listed agent advertises the account's labels as capabilities (with the same value, for a `name=value` label), and never writes the record itself.

## Other setup notes from the live run

- A classic pipeline definition created through the REST API was rejected until the job authorization scope `project` was set on **both** the definition and its phase.
- The PAT needs Agent Pools (read and manage). Its scope is organization-wide; it is not restricted to one pool, so pool permissions also matter. Keep it in the Keychain via `kinhin auth set --account NAME`, never in `config.yaml`.
- Parallelism is bounded by the organization's self-hosted parallel-job purchase and by Apple's limit of two macOS guests per Mac, not only by hardware. Several Macs each run their own scaler and see the same queue, so they can overprovision; multi-Mac operation is untested.
- The jobs' guest needs its own toolchains: the host's Xcode, Node and Android SDK are not inherited by a VM.

## Before full support: still to verify against a live service

- That an exported `kinhin_docker=true` environment variable is picked up as a capability by the agent, and that the demand arrives as `kinhin_docker`.
- That `installdependencies.sh` under `sudo` succeeds on the Tart Linux image and that `Agent.Listener --version` runs there.
- That the 60 s busy grace never reaps an agent mid-job, and how often an idle agent blips offline before its first job (each such blip costs a respawn under the 15 s idle grace).
- That a request carries `reservedAgent` before `assignTime`, as the queued rule assumes.
- That a redirect really is how an expired PAT presents on Azure DevOps Services and Server.
- That sequential registration of several runners in one VM is fast enough.
- Real application builds, and scaling across several Macs.

## Verified

2026-10-01, against:
- <https://learn.microsoft.com/en-us/azure/devops/integrate/concepts/rest-api-versioning>
- <https://learn.microsoft.com/en-us/rest/api/azure/devops/distributedtask/pools/get-agent-pools?view=azure-devops-rest-7.1>
- <https://learn.microsoft.com/en-us/rest/api/azure/devops/distributedtask/agents?view=azure-devops-rest-7.1>
- <https://learn.microsoft.com/en-us/rest/api/azure/devops/distributedtask/agents/delete?view=azure-devops-rest-7.1>
- <https://learn.microsoft.com/en-us/rest/api/azure/devops/distributedtask/requests/list?view=azure-devops-rest-7.1>
