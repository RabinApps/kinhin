# GitHub

How kinhin talks to GitHub Actions, and how that compares with GitHub's current REST API docs.

[← Back to README](../../README.md) · [Forge reference index](README.md) · [Setup guide](../forges.md)

## Overview

|             |                                                                                                                                                                                                                                                                                                       |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Forge id    | `github`                                                                                                                                                                                                                                                                                              |
| Hosting     | github.com by default. With an `instance` on the account, kinhin uses that host instead: GHES and GHEC data residency are both supported. For GHES the host is your server's base URL; for GHEC data residency it is the `api.*.ghe.com` host. See [Enterprise instance](#enterprise-instance) below. |
| Scope       | `owner/name` (one repository) or an org name. `actionsBase` is `/repos/{scope}/actions` or `/orgs/{scope}/actions`.                                                                                                                                                                                   |
| `instance`  | Optional. github.com when absent (the default); a GHES base URL (`https://github.example.com`) or a GHEC data-residency host (`https://acme.ghe.com`) otherwise.                                                                                                                                      |
| Source      | `Sources/KinhinKit/Forges/GitHubClient.swift`, `GitHubClient+Runs.swift`, `GitHubForge.swift`, `GitHubModels.swift`                                                                                                                                                                                   |
| Live-tested | Yes. This is the only forge exercised against the real service.                                                                                                                                                                                                                                       |

## Auth

`Authorization: Bearer <PAT>` (`GitHubClient.swift:157`). Both fine-grained and classic personal access tokens work. Permission lists live in `TokenRequirements.github(scope:instance:)`.

| Token        | Repository scope                                                        | Organization scope                                                                                    |
| ------------ | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Fine-grained | Administration: read and write; Actions: read-only; Metadata: read-only | Organization "Self-hosted runners": read and write; repository Actions: read-only on all repositories |
| Classic      | `repo`                                                                  | `admin:org`, `repo`                                                                                   |

GitHub's docs agree: runner endpoints need repository `admin` or organization `admin:org` (plus `repo` for private repositories).

## API version and base URL

|                        | We send                                                                                                                                                                                                             | GitHub documents (verified 2026-10-01)                                                                                                       |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Base                   | `https://api.github.com` when `instance` is absent. With an enterprise `instance`, the client derives `apiBase` from the host: `https://api.<host>` for `*.ghe.com`, or `https://<host>/api/v3` for any other host. | `https://api.github.com`; GHES uses `{protocol}://{hostname}/api/v3` and GHEC data residency uses `{protocol}://api.SUB.ghe.com`.            |
| `X-GitHub-Api-Version` | `2022-11-28` (`GitHubClient.swift:160`)                                                                                                                                                                             | Two supported versions: `2022-11-28` (supported until 2028-03-10) and `2026-03-10` (no end date). An absent header defaults to `2022-11-28`. |
| `Accept`               | `application/vnd.github+json`                                                                                                                                                                                       | Same                                                                                                                                         |

GitHub supports each version for 24 months after the next one ships, signals retirement with `Deprecation` and `Sunset` headers, and answers `410 Gone` once a version is retired.

**Diff of the two versions for kinhin's endpoints:** a comparison of the published OpenAPI descriptions (`api.github.com.2022-11-28.json` vs `.2026-03-10.json`) shows the same path set, and every endpoint kinhin calls has an identical definition. The only differences are on `POST /user/repos` and `POST /orgs/repos`, which kinhin does not call. Moving to `2026-03-10` is therefore a no-op for kinhin today.

## Endpoints used

| Method | Path                                                                                           | Purpose                                                        | Code                              |
| ------ | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------- | --------------------------------- |
| POST   | `{actionsBase}/runners/registration-token`                                                     | Mint a runner registration token (1 h lifetime)                | `GitHubClient.swift:243`          |
| GET    | `{actionsBase}/runners?per_page=100&page=N`                                                    | List runners                                                   | `GitHubClient.swift:323`          |
| DELETE | `{actionsBase}/runners/{id}`                                                                   | Remove a runner                                                | `GitHubClient.swift:344`          |
| GET    | `/repos/{repo}/actions/runs?status=queued\|in_progress&per_page=100&page=N`                    | Demand and running jobs (repo scope; org scope per repository) | `GitHubClient+Runs.swift`         |
| GET    | `/orgs/{org}/actions/runs`                                                                     | Not used (undocumented)                                        | none                              |
| GET    | `/repos/{repo}/actions/runs/{id}/jobs?per_page=100` (org mode: `{actionsBase}/runs/{id}/jobs`) | Job labels for matching                                        | `GitHubClient+Runs.swift:139-141` |
| GET    | `/user/repos?affiliation=owner,collaborator,organization_member`                               | Repository picker                                              | `GitHubClient.swift:270`          |
| GET    | `/orgs/{org}/repos`, `/users/{owner}/repos`                                                    | Repository picker, org and user                                | `GitHubClient.swift:272-274`      |

## Enterprise instance

When an optional `instance` is set on the GitHub account, kinhin targets that host instead of github.com in every surface that has an instance:

- **GHES (GitHub Enterprise Server):** use your server's base URL, for example `https://github.example.com`. The REST base becomes `https://github.example.com/api/v3`.
- **GHEC data residency:** use the data-region host, for example `https://acme.ghe.com`. The REST base becomes `https://api.acme.ghe.com`.

The runner's own `--url` still uses the `host/<scope>` form (for example `https://github.example.com/acme` or `https://acme.ghe.com/acme`) exactly as for github.com. All token-creation URLs, register/shard addresses, health-check probes and permission checks derive the right host from the account's `instance`, so github.com stays the default when `instance` is absent.

Token-creation and settings links are rendered per instance by `OrgPermissionProbe.settingsURL(for:instance:)`: the `*.ghe.com` form keeps the host as-is, while any other host points at `https://<host>/`.

## Scale sets (future direction)

GitHub's supported autoscaling path is runner scale sets plus JIT runner configuration (see [`actions/scaleset`](https://github.com/actions/scaleset)). The scale-set message API is Public Preview and, like the endpoint removed above, is not in any published OpenAPI description. kinhin keeps polling documented per-repository endpoints until the message API is documented. Only the opt-in mode below registers with JIT; the classic path still hands the VM a shared token (audit finding 2).

### Scale set mode in kinhin

kinhin has an opt-in scale-set mode for GitHub accounts. It is not the default and does not replace the documented REST poll. When a GitHub account has `scale_set:` set, kinhin uses the Actions-service message path for demand instead of polling workflow runs, and registers spawned runners with JIT configs.

```yaml
accounts:
  - name: github
    forge: github
    scope: your-org
    scale_set:
      name: kinhin # the scale set's name, and a label jobs may request via runs-on:
      runner_group: "Default" # case-sensitive: GitHub's built-in group is "Default"
```

`name` is required and must be a valid `runs-on:` label. `runner_group` is optional in the file
but not in effect: it defaults to the lowercase string `default`, which never matches GitHub's
built-in group `Default`, because the lookup is an exact, case-sensitive name match — every org
has that one group already, so the fix is spelling, not creation. Take the name from your org's
runner-groups page and set it verbatim; [Troubleshooting scale sets](#troubleshooting-scale-sets)
walks through the error, the fix, and the restart an account-level edit needs.

**Workflows target a scale set by its name.** GitHub keeps only a scale set's name (plus its own
`self-hosted`/architecture labels) on github.com, so `runs-on: [self-hosted, macos, xcode]` can never
reach one. kinhin therefore creates one scale set per pool, and one per named `images:` entry, and the
name picks where the job runs:

| `runs-on:`         | Runs on                                           |
| ------------------ | ------------------------------------------------- |
| `kinhin`           | the Tart (macOS) pool — the `scale_set.name` itself |
| `kinhin-container` | Apple containers (Linux)                          |
| `kinhin-docker`    | Docker slots (Linux)                              |
| `kinhin-host`      | the unisolated host pool (needs a host route)     |
| `kinhin-<image>`   | a named `images:` entry, e.g. `kinhin-xcode`      |

A fleet with a single pool and no named images keeps just `kinhin`. The set a job arrives on decides its
pool (it overrides repo and workflow routes), and a runner registers in the set matching its pool and image.
The names appear in the log at start (`listens on scale sets: …`). Pools or images added later need a
restart to get their sets.

Implementation notes:

- Admin exchange goes through `POST /actions/runner-registration` and returns an Actions-service URL plus a JWT.
- Scale-set and runner-group state is managed under `api-version=6.0-preview`.
- Demand comes from a long-poll message session plus scale-set statistics, not from `GET .../workflow-runs`.
- Runner registration uses `POST .../generatejitconfig` and the in-VM `config.sh --jitconfig` path.
- The listener service, client, and JIT adapter live in `Sources/KinhinKit/Fleet/` and `Sources/KinhinKit/Forges/` (see [architecture](https://github.com/RabinApps/kinhin/blob/main/docs/architecture.md) for the layout).

Caveat: because the message API is still preview and not in GitHub's published OpenAPI descriptions, the endpoint set and versioning should be re-verified when GitHub updates the API.

### Scale-set troubleshooting (kinhin side)

The listener service log lines are tagged `[scaleset]` and live in `~/Library/Application Support/Kinhin/logs/kinhin.log` (the app; `kinhin logs -n 200` from the CLI).
Three signatures cover almost everything.

#### `runner group 'default' was not found; create it in GitHub before attaching`

The full line is `scale-set message service failed: runner group 'default' was not found; create
it in GitHub before attaching`, repeated every few seconds as `statistics poll failed` and
`session refresh failed`. The group exists — kinhin's lookup is what fails:

- Every organization has exactly one built-in runner group, and GitHub names it **`Default`**
  (capital D).
- `scale_set.runner_group` defaults to the lowercase string `default`, and kinhin resolves the
  group with an **exact, case-sensitive** name match: the `groupName=` filter is re-checked
  locally against the full group list, so `default` never matches `Default`, no scale set is
  ever created, and the listener keeps retrying with the same message.

Name the group yourself, spelled byte-for-byte as GitHub spells it:

```yaml
accounts:
  - name: github
    forge: github
    scope: your-org
    scale_set:
      name: kinhin
      runner_group: "Default" # case-sensitive; GitHub's built-in group is "Default"
```

Read the spelling off your org's runner-groups page
(<https://github.com/organizations/OWNER/settings/actions/runner-groups>) — `default`, `Default`
and `DEFAULT` are three different answers to kinhin. Creating an _additional_ runner group needs
the GitHub Team plan; on Free, the built-in `Default` is the only group there is, and it isthe right target for a first scale set.

`scale_set:` is account-level config, so a fleet that is already running picks the change up only
when the engine is rebuilt — restart the app (or the daemon) after editing it. (Routing, budget
and label edits are the ones that apply live; everything else waits for a rebuild.)

#### `cd: /Users/admin/actions-runner-N: No such file or directory`

`bash: line …: cd: …` in the in-VM registration script: the image has no per-runner directory for
the slot the fleet is asking for, which is a `runners_per_vm` bake/fleet mismatch. Scale-set mode
uses the same baked image as classic mode, so bake with the density you run (or run the density
you baked with) and re-run `kinhin image prepare`.

#### `could not pin the guest's SSH host key … connecting without host key verification`

A boot/SSH reachability issue, not a registration-material issue — see
[Known limits](../../security.md#known-limits). Establish that one VM can boot and register before
scaling it.

#### A job stays queued with no `[scaleset]` error

GitHub assigns a job to a scale set only when the scale set carries **every** label the job
requests. kinhin creates one scale set per account, labelled with `labels:` from the account entry
when it is present, otherwise the fleet's `labels:`, plus the scale-set name (which is itself a
valid `runs-on:` label). A job asking for anything else — an image label such as `xcode`, or the
pool marker `kinhin-container` — is never assigned to it. Make the configured labels cover what
your workflows request, or leave `scale_set:` off and let the classic poller route per pool.

**`session conflict` after a restart.** GitHub allows one live message session per scale set. If kinhin exits without
cleaning up (force quit, crash), GitHub keeps the old session until its lease lapses and answers `409` to the next one.
kinhin records the session id under its state directory and deletes the leftover one on the next start, so a restart
normally attaches immediately. If the log keeps saying GitHub holds a session kinhin has no record of, another kinhin
instance (or an earlier run on another machine) is still using the scale set; it frees up on its own once that stops.
Cancelling a workflow has no effect on the session, and nothing needs to be re-created — the scale-set name is your
`runs-on:` label, so it stays fixed.

If the listener can't refresh statistics or the session drops, the engine keeps the last known snapshot briefly; if that keeps failing, re-check the account token and scopes (organization self-hosted-runner permissions).

## Pipeline view

The app's live pipeline view reads `GET /repos/{repo}/actions/runs?status=in_progress` and each run's `/actions/runs/{id}/jobs`. The job payload already carries `steps[]` (name, status, conclusion, number, timestamps) and `html_url`, so it costs no request beyond the running-attribution poll. The runner's job is found by `runner_name`.

Step output is sliced from `GET /repos/{repo}/actions/jobs/{id}/logs` (a redirect to a signed URL, fetched without the token) by each line's timestamp and the step start times.

## Registration flow

- Registration mode `sharedShortLived`, exit semantics `deregisters` (`GitHubForge.swift`).
- Token lifetime: about one hour, cached per account by `RegistrationTokenCache` (`Fleet/FleetEngine+Accounts.swift`, `token_ttl` in config).
- The runner starts with `config.sh --url --token --labels --unattended --ephemeral`, then `run.sh` (`Images/RunnerBootstrap/RunnerBootstrap+Linux.swift:184-206`).
- kinhin does **not** use JIT runner configuration. GitHub documents `POST /{orgs|repos}/.../actions/runners/generate-jitconfig` (body: `name`, `runner_group_id`, `labels`), which is present in every API version and in GHES. JIT would remove the shared token from the VM, which is a hardening opportunity (see [Audit findings](#audit-findings)).

## Demand and label matching

- `queuedJobs(matching:)` and `runningJobs(matching:)` count a job only when the fleet's labels are a subset of `job.labels` and `status` is `queued` or `in_progress`.
- A running job maps back to a VM through `runner_name`.
- The client reads workflow _runs_ first (`status=queued` and `status=in_progress`), then each run's jobs. It reads at most 50 runs per poll (`maxRunsPerPoll`).

## Pagination, rate limits, retries

- Page-number loops with `per_page=100`, stopping at `total_count`, an empty page (runs, runners) or a short page (repos).
- A conditional-GET (ETag) cache absorbs repeat polls; a `304` is served from cache (`ConditionalGetCache.swift`).
- Rate limits: a `403` with `X-RateLimit-Remaining: 0` throws `rateLimited(resetAt)`; any other `403` is retried as a possible secondary limit; `429` and `5xx` are retried; up to 3 retries, backoff 2^n capped at 8 s.
- GitHub is the only client with its own retry loop instead of `withTransientRetry`.

## Self-hosted notes and minimum versions

- GHES and GHEC data residency are supported with an account `instance`: GHES is `https://<hostname>` with a `/api/v3` REST base, and GHEC data residency uses `https://api.<subdomain>.ghe.com`.
- The `X-GitHub-Api-Version` values a given GHES release accepts were **not verified** here; GitHub's page on API versions says nothing about GHES. Verify the header against a real instance before relying on it.
- The GHES and GHEC runner endpoints kinhin calls were checked against the published OpenAPI descriptions (`ghes-3.14`, `ghes-3.22`), which contain the same runner, run and job endpoints kinhin uses.

## Version sensitivity

| Item                       | Varies by               | Detail                                                                                                 |
| -------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------ |
| `X-GitHub-Api-Version`     | github.com              | `2022-11-28` and `2026-03-10` are identical for the endpoints kinhin calls.                            |
| Base path                  | github.com vs GHES/GHEC | `/` for github.com, `/api/v3` for GHES, `/api/v3` for GHEC data residency (`api.<subdomain>.ghe.com`). |
| `/orgs/{org}/actions/runs` | all                     | Not used (undocumented).                                                                               |

## Audit findings

1. **Resolved (2026-10-01): undocumented endpoint.** `GET /orgs/{org}/actions/runs` is absent from the OpenAPI descriptions for both github.com versions and from GHES 3.14 and 3.22. It used to be the classic-token fast path, with a per-repository fallback on 404. kinhin never calls it now: org scope reads each repository's runs via the documented `GET /repos/{repo}/actions/runs`.
2. **JIT config unused** (see Registration flow). Ephemeral runners with a shared registration token are valid, but JIT is GitHub's recommended path for ephemeral runners.
3. **GitHub Enterprise Server and GHEC data residency are supported through the optional `instance` field.** The base URL is no longer hard-coded; it falls back to `https://api.github.com` and github.com for the default case.
4. **Documented status values are wider than the ones used.** GitHub lists `queued`, `in_progress`, `waiting`, `pending`, `requested` as run statuses. kinhin polls only `queued` and `in_progress`, so a run held in `waiting` (for example on an environment approval) is not counted as demand, which is arguably correct. Recorded here as intent, not a bug.

## Verified

2026-10-01, against:

- <https://docs.github.com/en/rest/about-the-rest-api/api-versions>
- <https://docs.github.com/en/rest/actions/self-hosted-runners>
- <https://docs.github.com/en/rest/actions/workflow-runs>
- OpenAPI descriptions: <https://github.com/github/rest-api-description> (`api.github.com` 2022-11-28 and 2026-03-10, `ghes-3.14`, `ghes-3.22`)
