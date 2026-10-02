# Plan: GitHub Enterprise (GHES + GHEC data residency) Actions support

## Context
kinhin's `github` forge hardcodes `api.github.com` / `github.com`, so it cannot talk to GitHub Enterprise Server
(`https://HOST/api/v3`) or GHEC with data residency (`https://api.SUB.ghe.com`). Goal: let a GitHub account carry an
`instance` host and have every request, runner registration URL, token-check message and runner download honor it.
GHEC on github.com already works and must stay unchanged.

Decisions (user-confirmed): support GHES + GHEC data residency; extend the existing `.github` forge with an
`instance` field rather than adding a new `ForgeID` (a new case would duplicate `GitHubClient` and miss every
`.github` special case: `ForgeDemand.swift:39-64`, `CredentialRotation.swift:26,35`, `primaryGitHub`,
`AuthStatusReport.swift:109`). `docs/adding-a-forge.md` therefore does not apply as written.

Scope for v1: PAT auth, polling only (as today), registration-token flow (as today, `GitHubForge.swift:13-14`).
Out of scope: GitHub App auth, JIT config, webhooks, runner scale-set API, enterprise-scope runners.

## Sourced facts the design rests on
(Agent research, fetched 2026-10-02; re-verify items marked ⚠ against a real instance.)
- GHES REST base is `http(s)://HOSTNAME/api/v3` (docs.github.com/en/enterprise-server@latest/rest/overview/resources-in-the-rest-api).
- GHEC data residency API is `https://api.SUBDOMAIN.ghe.com` (docs.github.com/en/enterprise-cloud@latest/rest/using-the-rest-api/getting-started-with-the-rest-api).
  ⚠ Runner-endpoint examples on that page still show api.github.com; the pattern is from the base-URL page.
- Registration-token endpoints (`POST /repos|orgs/.../actions/runners/registration-token`), runners list/delete,
  workflow runs `?status=queued|in_progress`, run jobs (`labels`, `runner_name`) all exist on GHES
  (docs.github.com/en/enterprise-server@latest/rest/actions/{self-hosted-runners,workflow-runs,workflow-jobs}).
- Registration tokens expire after one hour (GHES add-runners page).
- GHES rate limits are disabled by default; admins may enable them (rest/using-the-rest-api/rate-limits-for-the-rest-api).
  Client must tolerate missing `X-RateLimit-*` headers (`ForgeRateLimit` is optional already).
- Supported GHES: 3.19–3.22 safe set (admin/all-releases). Minimum runner per GHES: 3.19→2.328.0, 3.20→2.330.0,
  3.21→2.331.0, 3.22→2.334.0 (same page). Release page warns the newest runner may not yet be available to an
  enterprise (progressive rollout), and `--disableupdate` has a 30-day limit (GHES 3.14 runner docs).
- Custom CA: set `NODE_EXTRA_CA_CERTS`, `GIT_SSL_CAINFO`, fallback `SSL_CERT_FILE` before starting the runner
  (github.com/actions/runner/blob/main/docs/checks/sslcert.md). Runner must restart after cert changes.
- GHES prerequisites: Actions enabled, external blob storage, self-hosted runners only; `actions/checkout` resolves
  locally first, then github.com only with GitHub Connect, otherwise `actions-sync`.
- Runner `--url` for GHES is `https://HOST/<org>` or `https://HOST/<org>/<repo>`; runner validates Actions URL and
  GitHub URL share a host (runner `ConfigurationManager.cs`). ⚠ ghe.com form `https://SUB.ghe.com/ORG` inferred.

## Phase 1: Host plumbing in the GitHub client (core change)
1. `Sources/KinhinKit/Forges/GitHubClient.swift`
   - Add `instance: String?` to `GitHubCredentials` (:3-33); add `validate(instance:allowInsecureHTTP:)` mirroring
     `GitLabCredentials` (`GitLabModels.swift:9-47`) and reusing `ForgeHTTP.permitsScheme` (`ForgeHTTP.swift:15-29`).
   - Derive two URLs from the instance: `apiBase` and `webBase`.
     - nil → `https://api.github.com` / `https://github.com` (unchanged).
     - `*.ghe.com` host → `https://api.<host>` / `https://<host>`.
     - any other host → `https://<host>/api/v3` / `https://<host>`.
   - Replace the hardcoded base at :155 and `configureURL` at :25 with these. Keep `X-GitHub-Api-Version: 2022-11-28`
     (:164) but make it overridable; ⚠ confirm GHES 3.19 accepts it.
   - Pagination must pin to `apiBase` host (reuse the Gitea/GitLab host check pattern).
2. `GitHubClient+Runs.swift:176-201` (`jobLog`): GHES redirects log downloads to blob storage on another host.
   `ForgeHTTP.RedirectGuard` (`ForgeHTTP.swift:48-60`) blocks cross-host redirects. Keep token-less fetch of the signed
   URL but allow the redirect for log fetches only; ⚠ test against a real GHES (needs instance).
3. `GitHubClient+ProjectFile.swift:12-22`: contents API path works under `/api/v3`; verify via stub test.
4. Error strings (`GitHubClient.swift:47-61`), `TokenRequirements.swift:44-45` (token-creation URLs →
   `https://<webBase>/settings/...`), `OrgPermissions.swift:62`: parameterize host. Fine-grained PAT on GHES needs
   "Administration" (repo) / "Self-hosted runners" (org) per GHES permissions pages; update copy accordingly.

## Phase 2: Config and engine wiring
1. `Config/AccountConfig.swift:17,26` already has `instance` and `allowInsecureHTTP`. Remove `github` from the
   rejection at `ConfigLoader+Sections.swift:76` ("instance and labels apply to gitea accounts only") for `instance`
   only; keep `labels` rejected for GitHub. Add `.github` handling next to `selfHosted` (:64) without moving it into
   that list (github.com stays hosted by default).
2. Primary account: `KinhinConfig.primaryGitHub`/`.repo` (`ConfigModel.swift:104-113`) have no instance. Add a
   top-level `github_instance` (or equivalent) so the primary account can target GHES; flows into
   `FleetEngine.swift:129-134,195`.
3. `GitHubClientFactory.make` takes `GitHubCredentials` (`GitHubClientFactory.swift`); once `instance` is in the struct
   it flows through automatically. Update direct constructors that bypass the factory:
   `ProjectImageService.swift:169-182`, `ConnectModel.swift:115`, `TokenHealthCheck.swift:28,107,246`,
   `DoctorReportBuilder*.swift`, `AuthCommand.swift:92,294,383-384,404`.
4. Keychain: `TokenStore.swift:10-23` keys by `ForgeID` + account name; a GHES account uses a named account, so no
   change. The reserved `github` name keeps the legacy item.
5. `ForgeDemand.swift:39-64` tie-break and `FleetEngine+Accounts.swift:59,69` need no logic change, only checking they
   don't assume github.com.

## Phase 3: Runner agent bootstrap for GHES
1. Registration URL already flows through `GitHubForge.registrationURL()` (`GitHubForge.swift:31-33`) into
   `config.sh --url` for Tart (`Runtime.swift`), Linux container (`LinuxContainerCLI.swift`) and host
   (`HostRuntime.swift`). Verify each uses `registrationURL()` and not a literal.
2. Runner version: today `RunnerVersions.swift:66` pulls `releases/latest` from github.com and
   `RunnerBootstrap+Verification.swift:43,55` verifies the tarball digest. For GHES add a floor check: bake a runner
   ≥ the minimum for the instance's GHES version (table above), and warn if the instance is outside 3.19–3.22.
   Open question to resolve in implementation: whether "latest" is accepted by an older GHES (progressive-rollout
   warning). Default: use latest, with `--disableupdate` removed so the server-driven self-update remains available,
   and add a doctor check that surfaces a version-rejected registration clearly. ⚠ Needs a real GHES to confirm.
3. Custom CA / proxy: add optional `ca_bundle` (PEM path) to the account. On bake/boot, install it into the guest and
   export `NODE_EXTRA_CA_CERTS`, `GIT_SSL_CAINFO`, `SSL_CERT_FILE` before `config.sh`/`run.sh`. The host-side
   `URLSession` must trust the same CA (custom trust evaluation in `ForgeHTTP.session`, scoped to the instance host).
   Touch points: `ImagePreparer.swift:164,264-268`, `LinuxImageBaker.swift:92,113`, `HostAgentInstaller.swift:86,180`.
4. Network allow-list doc: GHEC data residency runners need `*.actions.SUB.ghe.com`, `*.SUB.ghe.com`,
   `*.githubassets.com`, `*.githubusercontent.com`, `*.blob.core.windows.net`, `auth.ghe.com`.

## Phase 4: CLI and App UI
- `AuthCommand.swift`: `checkGitHub` honors instance; add `--instance` to the GitHub add/replace flow; help text.
- `ForgeConnectionModel` (+`+Config`) and `AccountsModel`: show an optional "Enterprise host" field for GitHub with
  the same validation as GitLab; token-help link points at the instance.
- `TokenHealthCheck`: GHES-aware messages (rate limiting off ≠ error).

## Phase 5: Tests (copy existing patterns)
- `StubProtocol` (`Tests/KinhinTestSupport/StubProtocol.swift`) in `GitHubClientTests`: assert host and `/api/v3`
  path prefix for GHES, `api.SUB.ghe.com` for data residency, unchanged for default; pagination off-host rejected;
  `jobLog` redirect to another host allowed only for logs.
- `Config/` tests modeled on `GitLabAccountConfigTests` and `InsecureHTTPAccountConfigTests`: `instance`,
  `allow_insecure_http`, github-with-labels still rejected.
- `FakeGitHub` default `configureURL` extended; engine tests via `GitHubClientFactory` injection
  (`MultiAccountEngineTests.swift:44`).
- Registration script tests asserting the `--url` host and CA env exports; `TokenRequirementsTests`, `LogRedactorTests`.
- Use `Mutex` for any new global state; no `nonisolated(unsafe)`.

## Phase 6: Docs
- `docs/forges/github.md` (it already notes GHES API-version is unverified at :88-89): add Enterprise section with
  host forms, token permissions, CA setup, version table, network allow-list, and the `actions/checkout` /
  GitHub Connect caveat. Update `docs/forges.md`, website sidebar, `CHANGELOG.md`.
- Replace the unverified-claim note once tested against a real instance. Don't copy docs into `website/`.

## Commit plan (CONTRIBUTING: mechanical vs behavior separate)
1. Credentials/URL derivation + client + tests. 2. Config/engine/CLI/App wiring + tests. 3. Runner bootstrap + CA +
version floor. 4. Docs.

## Verification
- `swift build`, `swift test`, `swift format lint --strict -r Sources Tests`; `scripts/tsan.sh` (touches shared
  state/session trust); `bash scripts/docs-lint.sh` and `cd website && npx vitepress build`.
- Unit-level: stubbed hosts as above. End-to-end (cannot be done in CI, needs a real instance): a GHES 3.19+ trial
  or a ghe.com tenant: add account with `instance`, `kinhin auth check`, queue a job with matching label, confirm
  a runner registers via `--url https://HOST/<scope>`, runs, deregisters; fetch a job log (redirect case); run with a
  private CA to confirm the checkout step and runner connect.

## Risks / open items
- No real GHES available in CI: the log-redirect, API-version header, runner-version acceptance and ghe.com
  `--url` form are doc-derived and must be validated manually before release.
- Enterprise-scope runners and GitHub App auth are not documented for fine-grained permissions on GHES; deferred.
- 3.18 and earlier are out of GitHub support; floor at 3.19 in docs, warn rather than block.
