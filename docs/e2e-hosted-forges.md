# Setting up the hosted e2e lanes

How to create the throwaway Buildkite, Azure DevOps and Bitbucket accounts the [end-to-end suite](e2e-testing.md) needs, and wire them to CI. Each lane is **gated**: with its secrets unset it is skipped silently, so you can turn them on one at a time.

[← Back to End-to-end testing](e2e-testing.md) · [Forge reference](forges/README.md) · [Beta 3 plan](plans/beta-3-plan.md)

> **The fixtures have not run against the real services yet.** The first run of each lane is its acceptance test, so expect to fix the fixture as well as the setup. [What to check on the first run](#what-the-first-run-must-confirm) lists what is still unknown. The third-party screens below were written from the vendors' documentation and may be labelled differently by the time you open them.

## Before you start

- **Use throwaway accounts.** The suite creates and deletes pipelines, files, runners and agent tokens, and the Azure PAT is copied into every runner VM. Do not point it at an organization, project or repository that holds real work.
- **Nothing here runs on your Mac.** The lanes run in CI on the dedicated Mac labelled `kinhin-e2e`, which must be [registered](e2e-testing.md#what-the-machine-needs) first. Never run `scripts/e2e.sh` locally. The API checks below are plain `curl` calls and are safe to run anywhere.
- **Names.** The secret names are fixed by [`.github/workflows/e2e.yml`](../.github/workflows/e2e.yml). The values you pick (organization, project, pool, repository) are free.
- **Keep the tokens out of shell history.** The commands below read them from the clipboard or a prompt. Use short expiry dates and revoke each token when you finish a test pass.

Summary of the secrets:

| Lane | Secret | Value |
| ---- | ------ | ----- |
| Buildkite | `KINHIN_E2E_BUILDKITE_TOKEN` | REST API access token |
| Buildkite | `KINHIN_E2E_BUILDKITE_SCOPE` | `organization-slug/cluster-name` |
| Bitbucket | `KINHIN_E2E_BITBUCKET_TOKEN` | Repository access token |
| Bitbucket | `KINHIN_E2E_BITBUCKET_SCOPE` | `workspace/repository` (lowercase slugs) |
| Azure DevOps | `KINHIN_E2E_AZURE_TOKEN` | Personal access token (PAT) |
| Azure DevOps | `KINHIN_E2E_AZURE_ORG` | Organization name, or its URL |
| Azure DevOps | `KINHIN_E2E_AZURE_PROJECT` | Project name |
| Azure DevOps | `KINHIN_E2E_AZURE_POOL` | Self-hosted agent pool name |

Optional, also as repository secrets or workflow `env:` entries: `KINHIN_E2E_BUILDKITE_REPO`, `KINHIN_E2E_AZURE_REPO`, `KINHIN_E2E_AZURE_FLOOR`. The workflow only passes through the secrets listed in its `env:` block, so add a line there for an optional one you want to use.

## Buildkite

Buildkite is hosted only; there is no server to run. kinhin's agents join a **cluster**, so the lane needs an organization, a cluster and a queue.

### 1. Create the organization and cluster

1. Sign up at <https://buildkite.com> and create an organization (a free plan is enough). The URL slug, for example `kinhin-e2e-yourname`, is the organization part of the scope.
2. In the organization, open **Agents → Clusters** and create a cluster, for example `e2e`. A new organization may already have a default cluster; any cluster works.
3. Open the cluster, go to **Queues** and create a queue with the key **`kinhin`**. It must be a *self-hosted* queue (not a hosted one). The key must be exactly `kinhin`: the fixture looks for it and stops with the list of queues it found otherwise.

You do not create a pipeline, an agent token or a repository. The fixture creates one pipeline per job and deletes it afterwards, and kinhin mints its own cluster agent token.

### 2. Create the API token

1. Open <https://buildkite.com/user/api-access-tokens> and choose **New API Access Token**.
2. Under **Organization access**, tick only your throwaway organization.
3. Under **REST API Scopes**, tick:
   - `read_agents`, `write_agents`
   - `read_builds`, `write_builds`
   - `read_clusters`, `write_clusters`
   - `read_pipelines`, `write_pipelines`
   - `read_build_logs` (optional; only the app's pipeline view reads logs)
4. Create the token and copy it.

kinhin itself needs `read_agents`, `write_agents`, `read_builds`, `read_clusters` and `write_clusters` ([Buildkite](forges/buildkite.md#auth)); the fixture also needs `write_builds`, `read_pipelines` and `write_pipelines` to create pipelines and start builds.

### 3. Check it with curl

```bash
export BK_TOKEN="$(pbpaste)"   # the token you just copied
curl -s -H "Authorization: Bearer $BK_TOKEN" https://api.buildkite.com/v2/access-token
curl -s -H "Authorization: Bearer $BK_TOKEN" https://api.buildkite.com/v2/organizations/ORG/clusters
```

The first call must list every scope above. The second must show your cluster; copy its `id` and then check the queue:

```bash
curl -s -H "Authorization: Bearer $BK_TOKEN" https://api.buildkite.com/v2/organizations/ORG/clusters/CLUSTER_ID/queues
```

The response must contain an entry whose `key` is `kinhin`.

### 4. Store the secrets

```bash
gh secret set KINHIN_E2E_BUILDKITE_TOKEN --repo RabinApps/kinhin   # paste the token at the prompt
gh secret set KINHIN_E2E_BUILDKITE_SCOPE --repo RabinApps/kinhin --body "ORG/CLUSTER"
```

`CLUSTER` is the cluster's name or its UUID. The organization is the slug from the Buildkite URL, lowercase letters, digits and `-` only.

### Notes

- The pipeline names a placeholder repository (`https://github.com/RabinApps/kinhin.git`) and **skips the checkout**, so no source-control integration is needed. If the step does not accept `skip_checkout` on your agent version, set `KINHIN_E2E_BUILDKITE_REPO` to a repository the agents can clone.
- The job proves itself with `buildkite-agent meta-data set`, so the guest image needs nothing beyond the agent kinhin installs.

## Bitbucket Cloud

Bitbucket Pipelines runners are registered per workspace or per repository. The lane uses a **repository** scope so a token cannot reach anything else.

### 1. Create the workspace and repository

1. Sign up at <https://bitbucket.org> and create a workspace (for example `kinhin-e2e-yourname`). Its slug is the first half of the scope.
2. Create a **private** repository in it, for example `e2e`, with a **README so the main branch has a commit**. An empty repository cannot take the fixture's first push.
3. Open **Repository settings → Pipelines → Settings** and enable Pipelines. The fixture also enables it through the API, but the repository must be allowed to.

Self-hosted runner steps do not consume build minutes, but check your plan: repository access tokens have been limited to paid plans, so you may need a trial of Standard or Premium to create one. Verify this on your account.

### 2. Create the repository access token

1. In the repository, open **Repository settings → Security → Access tokens** (<https://bitbucket.org/WORKSPACE/REPO/admin/access-tokens>) and choose **Create repository access token**.
2. Give it these scopes:
   - **Repositories: Write** (the fixture commits `bitbucket-pipelines.yml`)
   - **Pipelines: Read** and **Pipelines: Write** (read steps and logs, enable Pipelines, start pipelines)
   - **Runners: Read** and **Runners: Write** (kinhin registers and deletes runners)
3. Set a short expiry, create it and copy it. It is shown once.

An app password does not work: it has no runner scopes. A workspace token also works for kinhin, but then the scope is just the workspace and the fixture needs a repository, so keep to the repository token.

### 3. Check it with curl

```bash
export BB_TOKEN="$(pbpaste)"
curl -s -H "Authorization: Bearer $BB_TOKEN" https://api.bitbucket.org/2.0/repositories/WORKSPACE/REPO
curl -s -H "Authorization: Bearer $BB_TOKEN" https://api.bitbucket.org/2.0/repositories/WORKSPACE/REPO/pipelines-config/runners
```

The first must return the repository, with a `mainbranch` entry. The second must answer `200` with a (probably empty) `values` list; a `403` means the token lacks the runner scopes.

### 4. Store the secrets

```bash
gh secret set KINHIN_E2E_BITBUCKET_TOKEN --repo RabinApps/kinhin
gh secret set KINHIN_E2E_BITBUCKET_SCOPE --repo RabinApps/kinhin --body "WORKSPACE/REPO"
```

Use the lowercase slugs from the URL, not the display names.

### Notes

- The fixture owns `bitbucket-pipelines.yml` in the repository: it rewrites the whole file on every job and deletes it in `stop()`. Do not keep anything else in it.
- Every job is a **custom** pipeline started through the API against the main branch, so pushes never trigger anything.
- Bitbucket keeps finished pipelines; the fixture stops running ones but cannot delete history.
- A Tart Linux guest needs a `linux` label on its pool; the lane's fleet config already carries one ([Bitbucket](forges/bitbucket.md#registration-flow)).

## Azure DevOps

Azure Pipelines is the most work: a project, a repository to hold the pipeline files, a self-hosted agent pool and a PAT.

### 1. Create the organization and project

1. Sign in at <https://dev.azure.com> and create an organization (for example `kinhin-e2e-yourname`).
2. Create a **private** project, for example `e2e`.
3. In **Repos**, make sure the project's own repository has a commit: choose **Initialize** with a README if it is empty. The fixture can create the first commit itself, but a normal default branch avoids surprises. To use another repository set `KINHIN_E2E_AZURE_REPO`.
4. A new organization may have no free parallel jobs. A private project gets one free **self-hosted** parallel job, which is all the lane needs (it runs one job at a time). If runs sit in "not started" with a message about parallelism, request the free grant at <https://aka.ms/azpipelines-parallelism-request> or buy one parallel job.

### 2. Create the agent pool

1. Open **Organization settings → Pipelines → Agent pools → Add pool**.
2. Choose **Self-hosted**, name it (for example `kinhin-e2e`) and tick:
   - **Grant access permission to all pipelines**. Without it, every run waits for a person to approve the pool and the lane times out.
   - **Auto-provision this agent pool in all projects** (or add the pool to the project under **Project settings → Agent pools**).
3. Leave it empty. kinhin registers and removes the agents itself.

The account that creates the pool is its Administrator. The PAT must belong to a user with the **Administrator** role on the pool, because kinhin deletes agents from it.

### 3. Create the PAT

1. Open the user menu → **Personal access tokens** (<https://dev.azure.com/ORG/_usersSettings/tokens>) → **New Token**.
2. Set the organization to your throwaway one and a short expiry.
3. Choose **Custom defined**, then **Show all scopes**, and tick:
   - **Agent Pools: Read & manage**
   - **Build: Read & execute**
   - **Code: Read & write**
   - **Project and Team: Read** (if creating pipelines is refused without it)
4. Create the token and copy it.

kinhin passes this PAT to every runner VM so the agent can register ([Azure DevOps](forges/azuredevops.md#registration-flow)), and the lane uses one token for both kinhin and the fixture. That is acceptable because the project is throwaway, but never reuse this token anywhere else.

### 4. Check it with curl

```bash
export AZ_PAT="$(pbpaste)"
curl -s -u ":$AZ_PAT" "https://dev.azure.com/ORG/_apis/distributedtask/pools?poolName=POOL&api-version=7.0"
curl -s -u ":$AZ_PAT" "https://dev.azure.com/ORG/PROJECT/_apis/git/repositories/REPO?api-version=7.0"
```

The first must list your pool with an `id`; the second must return the repository, with a `defaultBranch` (`refs/heads/main`) once it has a commit. A `203`, an HTML page or a redirect means the PAT is rejected.

### 5. Store the secrets

```bash
gh secret set KINHIN_E2E_AZURE_TOKEN --repo RabinApps/kinhin
gh secret set KINHIN_E2E_AZURE_ORG --repo RabinApps/kinhin --body "ORG"
gh secret set KINHIN_E2E_AZURE_PROJECT --repo RabinApps/kinhin --body "PROJECT"
gh secret set KINHIN_E2E_AZURE_POOL --repo RabinApps/kinhin --body "POOL"
```

`KINHIN_E2E_AZURE_ORG` can also be a full URL, which is how to point at an Azure DevOps Server collection.

### Notes

- Each job commits `/e2e/<name>-<nonce>.yml`, creates a pipeline in the `\kinhin-e2e` folder and starts a run. `stop()` cancels the runs, deletes the pipelines and removes the files.
- **Empty-pool risk.** Azure may fail a job at once when no agent in the pool advertises its demands, so kinhin never sees demand to scale up from. The lane runs **without** a runner floor on purpose, to find out. If the first run fails that way, set `KINHIN_E2E_AZURE_FLOOR=1` (add it to the workflow's `env:` block) so the lane runs with `min_runners: 1`, and record the result in [forges/azuredevops.md](forges/azuredevops.md#before-support-to-verify-against-a-live-service).

## Run the lanes

With the secrets stored, check them:

```bash
gh secret list --repo RabinApps/kinhin | grep KINHIN_E2E_
```

Then dispatch the workflow ([the machine must be registered](e2e-testing.md#what-the-machine-needs)):

```bash
gh workflow run e2e.yml --repo RabinApps/kinhin -f tier=local
```

A configured hosted lane joins the matrix automatically, beside the Gitea, Forgejo and GitHub cells. The workflow has no switch to run one forge alone; `KINHIN_E2E_FORGES=buildkite` narrows a run only if you add it to the workflow's `env:` block for that dispatch. Watch the run with `gh run watch --repo RabinApps/kinhin`.

A lane that is skipped did not find all its secrets. A lane that fails with `E2EError.unavailable` named a missing variable; one that fails with `cannot read` or `cannot list` could not reach the service with the token.

## What the first run must confirm

These are the unknowns the fixtures were written around. Record each answer in [the beta test log](plans/beta-test-log.md) and fix the fixture or the forge code where reality differs.

| Forge | Confirm |
| ----- | ------- |
| Buildkite | A build's JSON carries the `meta_data` the job set. `skip_checkout: true` is accepted. A job with `kinhin-runtime=docker` in its `agents:` reaches the docker pool. The `kinhin` queue is found. [More](forges/buildkite.md#before-support-to-verify-against-a-live-service) |
| Bitbucket | A custom pipeline starts from the API against the main branch. The step log contains the `E2E-PROOF-` line. The runner's labels match the step's `runs-on`. A repository token can list runners. [More](forges/bitbucket.md#before-support-to-verify-against-a-live-service) |
| Azure DevOps | An empty pool with a demanding job queues instead of failing. The pool needs no approval. `kinhin_docker` arrives as a capability demand. The run log contains the `E2E-PROOF-` line. [More](forges/azuredevops.md#before-support-to-verify-against-a-live-service) |

A forge is promoted only after its lane passes: see "Later, per forge" in the [beta 3 plan](plans/beta-3-plan.md#1-promote-buildkite-azure-pipelines-and-bitbucket-core).

## If a run leaves things behind

Teardown is part of every test, but a hard-killed run can leave remnants. [`scripts/e2e-sweep.sh`](../scripts/e2e-sweep.sh) cleans the Mac; the services need a manual look:

| Forge | Look for |
| ----- | -------- |
| Buildkite | Pipelines named `kinhin-e2e-*`; cluster agent tokens described `kinhin: buildkite @ <host>/<pid>`; connected agents |
| Bitbucket | `bitbucket-pipelines.yml` in the repository; runners under **Repository settings → Pipelines → Runners**; running pipelines (stop them) |
| Azure DevOps | Pipelines in the `kinhin-e2e` folder; files under `/e2e/` in the repository; agents in the pool |

Revoke the three tokens when you finish a pass.
