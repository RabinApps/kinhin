# Bitbucket Cloud

How kinhin talks to Bitbucket Pipelines runners, and how that compares with Atlassian's published API spec.

[← Back to README](../../README.md) · [Forge reference index](README.md) · [Setup guide](../forges.md)

## Overview

| | |
|---|---|
| Forge id | `bitbucket` |
| Hosting | Bitbucket Cloud only. The base is fixed at `https://api.bitbucket.org`; `instance` is unused. Bitbucket Data Center is not supported (not researched). |
| Scope | A workspace, or `workspace/repo`. |
| Source | `Sources/KinhinKit/Forges/Bitbucket/BitbucketClient.swift`, `BitbucketForge.swift`, `BitbucketModels.swift`, `BitbucketPipelinesFile.swift`; runner start-up in `Sources/KinhinKit/Images/RunnerBootstrap/RunnerBootstrap+Bitbucket.swift` |
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
| GET | `/2.0/repositories/{repo}/src/{commit}/bitbucket-pipelines.yml` | The pipeline file at the pipeline's commit, to learn each step's `runs-on` (a 404 means no file) | `BitbucketClient.sourceFile` |
| GET | `/2.0/repositories/{w}?sort=-updated_on` | Active repositories for a workspace scope | `BitbucketClient.swift` |
| GET | `/2.0/repositories/{w}?role=contributor` | Repository picker | `BitbucketClient.swift` |

All six runner operations (list, create, get, update, delete, at workspace and repository level) are in the published spec with the paths above.

## Pipeline view

The active pipeline (`PENDING` or `IN_PROGRESS`, from `/pipelines/?sort=-created_on`) and its `/steps` are shown, each
Bitbucket step as one job with its state and result. Which runner took a step is not public, so every running step is
marked as this VM's, and the API has no list of commands within a step (job-level).

Output is `GET /2.0/repositories/{repo}/pipelines/{uuid}/steps/{step}/log`.

## Registration flow

- Registration mode `perRunner`, exit semantics `idleGrace` (`BitbucketForge.swift:51-52`): the Bitbucket runner has no single-job mode, so it idles out.
- Each runner is created with labels `["self.hosted", "linux.shell" | "macos"] + account labels + pool labels`, de-duplicated case-insensitively; a label naming the other platform is dropped, so a runner never advertises both `macos` and `linux.shell` (`BitbucketForge.runnerLabels`).
- The platform label is `linux.shell` when the pool's or account's labels carry `kinhin-container`, `kinhin-docker`, `linux` or `linux.shell`, otherwise `macos`. The guest OS is not known when the runners are created, so a **Tart Linux VM needs a `linux` label on its pool or image**: the registration script compares the guest with the label the runners were created with and, on a mismatch, fails with a message naming that label instead of idling under labels no step matches.
- If a create call returns no OAuth secret, or a later runner of the same call fails, the half-created runner records are deleted again; records left under the same name by an earlier crashed run are deleted first.
- The credential bundle `workspaceUUID|repoUUID|runnerUUID|clientId|secret` is stored as the runner token (`BitbucketForge.swift:~118`). The agent starts with `--accountUuid --runnerUuid ...` (`RunnerBootstrap+Bitbucket.swift`), plus `--repositoryUuid` when the bundle carries one. The registration script waits 5 s and fails, with each dead runner's log tail, when a runner process has already exited.

## Demand and label matching

- The public API has no queued-steps endpoint, so demand is derived from steps of `PENDING` or `IN_PROGRESS` pipelines.
- The step payload carries no `runs_on`, so kinhin reads `bitbucket-pipelines.yml` at the pipeline's commit (cached per commit) and takes each step's `runs-on` from it. Only steps whose `runs-on` includes `self.hosted` (and not `windows`) count; cloud steps do not. When the file cannot be read, the step is counted as self-hosted, which errs towards one idle runner.
- A `PENDING` step counts as queued only when no earlier step of its pipeline has started and its stage is not `PAUSED` or `HALTED` (a future step behind a running one needs no runner yet).
- A workspace scope polls at most 20 recently active repositories; that list is cached for 30 s.
- A running self-hosted step marks every runner busy, because steps do not name their runner. A failed read counts as busy.
- A token that cannot list runners (403 or 404) is remembered; the engine then watches running steps instead.

## Pagination, rate limits, retries

`pagelen=100` and the `next` URL in the response body, up to 20 pages (`BitbucketClient.swift:18,173-177`); some calls take one page only. Next links are checked against a trusted host. `withTransientRetry` on network errors, 429 and 5xx.

## Self-hosted notes and minimum versions

Bitbucket Cloud has no instance version. Bitbucket Data Center is a different API and is out of scope; it was not researched.

## Version sensitivity

None. There is a single 2.0 API.

## Audit findings (live-run lessons, 2026-10-09)

Found by reading the code against what the live runs of other forges taught. These fixes were **made by code reading and unit tests with fakes only; none has been run against Bitbucket Cloud.**

What was wrong, and what changed:

- **The runner command was quoted twice**, so a VM or host runner exec'd a path with literal quotes and never started. The command is now passed as one shell word.
- **`repositoryUuid` was never passed** (the script referenced a flag variable nothing set). It is now `--repositoryUuid` when the credential bundle has one.
- **JDK layout.** The macOS Temurin tarball nests the JDK under `Contents/Home`; the launcher assumed `jdk/bin`. `runner.sh` now sets `JAVA_HOME` and `PATH` for either layout, and amd64 containers get the x64 JDK.
- **`updated_on` did not decode.** The workspace repository list modelled it as a `Date`, which Bitbucket's ISO string with microseconds fails, so every workspace-scope poll failed. It is kept as text.
- **Host teardown** matched `runner.sh`, but the wrapper `exec`s into the JVM, so the recorded pid no longer named it. It now matches the instance's `--workingDirectory`.
- **Labels** were `self.hosted` + platform + account labels only. Pool labels now join them (see Registration flow).
- **A Tart Linux VM could not be told from macOS.** It now needs a `linux` label, and registration fails with a clear message otherwise.
- **Demand counted every active step.** It now reads the pipeline file and counts only self-hosted steps that are waiting for a runner now.
- **A runner that died at start-up looked started.** Registration now fails with the runner's log.
- A token that cannot list runners no longer retries the list to its deadline; running steps are watched instead.

Still to verify live:

- That `/2.0/repositories/{repo}/src/{commit}/bitbucket-pipelines.yml` answers with the raw file for the commit taken from the pipeline payload, and that the commit is present for every pipeline kind.
- That a step's `name` in the steps API equals the `name:` in the YAML (unnamed steps are matched by a heuristic).
- That `state.stage.name` carries `PAUSED` and `HALTED` as assumed.
- That the runner starts end to end on a macOS VM, a Tart Linux VM (with a `linux` label), a container and the host, takes a step, and is removed again.
- That `--repositoryUuid` and the `runner.sh` wrapper behave as the runner package expects, and that `JAVA_HOME` is honoured.
- That a 5 s start-up liveness window catches a bad credential without failing slow starts.
- That a workspace access token can list runners (otherwise the 403 fallback path applies).

### Earlier findings (2026-10-01)


1. **Runner endpoints and scopes match the published spec.**
2. **Demand is approximate by design.** The step list does not carry the runner it ran on, and the payload has no `runs_on`, so kinhin reads the pipeline file instead (see the 2026-10-09 findings) and "busy" is a guess. That is an API limitation.
3. **Pipelines list is one page per repository**, newest first, so a burst of more than a page of recent pipelines can hide older queued ones. Low risk; recorded for completeness.
4. **Pipeline path has a trailing slash** (`/pipelines/`). The spec lists the collection path without one. Whether the server treats both forms alike was not verified.

## Verified

2026-10-01, against Atlassian's OpenAPI document (<https://dac-static.atlassian.com/cloud/bitbucket/swagger.v3.json>, runners, pipeline steps and their OAuth scopes). The runner HTML reference page could not be read, so field-level request and response bodies (`name`, `labels`, the returned OAuth credentials) were not re-checked.
