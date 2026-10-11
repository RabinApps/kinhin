# Beta launch checklist (v0.0.1-beta-1, Sunday, October 11, 2026)

Release checklist for [beta-launch-post-draft.md](beta-launch-post-draft.md). The draft describes the state we want. Every
claim that depends on a result not yet recorded sits inside a gate marker pair. Per gate, decide pass or fail, keep
exactly one block, and delete the other with its markers.

Marker forms in the draft: `GATE:Gn start` / `GATE:Gn end` (target text, keep on pass) and `FALLBACK:Gn start` /
`FALLBACK:Gn end` (what is true without the result, keep on fail). Inline `TODO(verify:Gn)` comments and `[MEASURE: ...]`
placeholders must be resolved too.

## Gates

| Id | Evidence needed | On pass | On fail |
| -- | --------------- | ------- | ------- |
| G1 | **Passed 2026-10-10, resolved in the draft.** `scripts/check.sh` full run green on `develop`. Re-run on the release commit before publishing. | Done. | — |
| G2 | **Passed 2026-10-10, resolved in the draft.** `scripts/e2e.sh --local`: Gitea and Forgejo on Docker and apple/container, pause and resume, daemon-crash reconciliation, the `max_runners` cap, long jobs, forge outage, no-floor scale-down, busy-fleet commands and routing. | Done. | — |
| G3 | **Passed 2026-10-10, resolved in the draft.** GitLab CE 18.4 lifecycle (job in guest, teardown, failing job) on Docker, apple/container, Tart Linux, Tart macOS and host. | Done. | — |
| G4 | **Not done, resolved in the draft (fallback: "Not done").** One week of the author's own CI on kinhin with no leaked VMs, containers or registered runners. | — | Done. |
| G5 | **Passed 2026-10-10, resolved in the draft.** `scripts/tsan.sh`: no ThreadSanitizer reports. One test that raced its own teardown under TSan (`DockerLifecycleTests.testRegistrationScriptFailureDoesNotLeaveAStrayContainer`) was fixed to wait for it. | Done. | — |
| G6 | **Kept in the draft; must hold before the post goes live.** Signed, notarized release published as the latest release (not a prerelease) and `curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh` works on a clean Mac. The repo must be public. | Done in the draft. | If the release cannot be published, put `FALLBACK:G6` back (no install command). Do not publish with a dead URL. |
| G7 | **Passed 2026-10-10, resolved in the draft.** `kinhin bench` (quick) on an M1 Max, 64 GB, macOS 27.0, Tart + apple/container, against the prepared `xcode` image: Tart cold boot to SSH 31.5 s, warm boot 9.5 s, container ready 1.4 s, Xcode clean build 13.3 s, incremental 3.5 s. Throughput at the two-VM cap is not measured by `bench` and is not claimed. | Done. | — |
| G9 | **Passed for 1.26 on 2026-10-10, resolved in the draft.** Gitea 1.26 with no floor on Docker and host; 1.24 on every runtime. Gitea 1.25 endpoints were probed but its lifecycle was not run; the draft does not claim it. | Done. | — |
| G10 | **Passed 2026-10-10, resolved in the draft.** The e2e host lane (`KINHIN_E2E_HOST=1`): consent required, the job runs in its sandboxed work directory, teardown removes it and stops the runner, on Gitea, Forgejo and GitLab CE. It ran in a sandbox on the development Mac, not a dedicated machine. | Done. | — |
| G8 | In-app updater: not testable until a second release exists. Not a pass or fail gate. | Nothing to change: the table row stays "Not exercised (this is the first release)". | Same. |

## Optional gates (Tier 2)

Do these only if time allows. None blocks the release. Each one that passes may earn a row in the draft's testing
table; each that does not is left out.

| Id | What to run for real, once |
| -- | -------------------------- |
| O1 | GitHub scale-set (JIT) mode with a throwaway repo or org |
| O2 | Mixed fleet: two accounts or forges on one pool. Routing by label and repo is done (e2e `FeatureTests`); workflow routes do not apply on Gitea/Forgejo |
| O3 | Warm pool and per-job toolchains: **done** by the e2e suite (Tart Linux warm pool; per-job installs on every guest). Still open: per-project toolchains (`.kinhin.yml`, derived images), shared cache, fork-PR safety |
| O4 | Out of scope for beta-1: Buildkite, Azure DevOps and Bitbucket are planned for a later beta and documented as not supported. |
| O5 | Security on real guests: `tart_softnet` isolation, SSH host-key pinning, redaction in logs and bundles |
| O6 | Daemon killed with several jobs in flight on a real fleet: nothing leaks |

**Scope is frozen.** Anything not done is "coming in beta-2", not a thin test.

## Publish steps

1. Resolve every gate above, then check nothing is left:
   `grep -nE 'GATE:|FALLBACK:|TODO\(verify|MEASURE' docs/plans/beta-launch-post-draft.md` must print nothing after you
   have removed the chosen blocks and their markers. Also delete the leading DRAFT comment.
2. Re-read the result against the evidence once, line by line. If a sentence claims something no gate backs, cut it.
3. Copy the resolved draft over `website/blog/introducing-kinhin-beta.md`. Keep the frontmatter; the date line is
   *Sunday, October 11, 2026*.
4. Update the date in `website/blog/index.md` to October 11, 2026.
5. Launch scope is GitHub, Gitea, Forgejo and GitLab CE; Buildkite, Azure DevOps and Bitbucket are "planned" everywhere.
   If forge or runtime status changes again, update the same facts in `docs/forges.md` (status table and "What has been
   tested"), `docs/compare.md` (the "Today only ..." line and the kinhin row), `docs/beta-roadmap.md` ("Where we are"),
   `docs/e2e-testing.md` (Status table), and the `MaturityTable` source plus its test
   (`Tests/KinhinKitTests/Core/MaturityTableTests.swift`). Then run `scripts/docs-sync.sh` to regenerate marked blocks;
   do not hand-edit between the markers.
6. Run `cd website && npx vitepress build` (fails on dead links).
7. Run `bash scripts/docs-lint.sh`, then `scripts/check.sh` (use `--fast` while iterating, full run before release).
8. Commit and push `develop`; CI must be green on the fleet.

Steps 1–4 are done (2026-10-10): the post is resolved and copied, and the blog index is dated.

## Launch day (Sunday, October 11)

In this order. Each step names how to check it.

1. **Build the release locally:** `NOTARY_KEYCHAIN_PROFILE=kinhin scripts/release.sh 0.0.1-beta-1`. Notarization can
   take hours; `scripts/notarize.sh status dist/kinhin-0.0.1-beta-1-arm64.dmg` shows where it is.
2. **Make the repository public:**
   `gh repo edit RabinApps/kinhin --visibility public --accept-visibility-change-consequences`.
3. **Let the fleet keep serving CI.** Org **Settings → Actions → Runner groups → Default**: allow public repositories,
   and set repository access to **Selected repositories** with only `kinhin`. Without this, every `kinhin-xcode` and
   `kinhin-container` job stays queued once the repository is public. Check: push a commit and watch `test` start.
4. **Fork pull requests need approval:**
   `gh api -X PUT repos/RabinApps/kinhin/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors`.
   They run only the hosted `fork` and `docs` jobs in `ci.yml`, never on the fleet.
5. **Rulesets** (Settings → Rules, available once public):
   - `main` and `develop`: changes through pull requests, required check `test`, CODEOWNERS review, no force-push, no
     deletion.
   - Tags `v*`: only you may create, update or delete them (a tag triggers `release.yml`).
6. **Release secrets behind a reviewer:** create the `release` environment with you as required reviewer, and move the
   six signing secrets (`MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `MACOS_SIGN_IDENTITY`, `NOTARY_API_KEY_P8`,
   `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`) from repository secrets into it.
7. **Require SHA-pinned actions:** Settings → Actions → General.
8. **Publish the release** (no `kinhin-xcode` tag build needed): the "Local publish" commands in `docs/releasing.md`,
   `gh release create v0.0.1-beta-1 --target <sha> --latest …`. Check:
   `curl -fsSLI https://github.com/RabinApps/kinhin/releases/latest/download/install.sh` answers 200.
9. **Gate G6:** run the install command on a clean Mac. If it fails, put the fallback text back in the post before the
   site goes up.
10. **Pages:** Settings → Pages → Source "GitHub Actions", custom domain `kinhin.dev`, DNS (A/AAAA or ALIAS to GitHub
    Pages), enforce HTTPS. Set the repository website to `https://kinhin.dev`.
11. **Publish the site:** fast-forward `main` to `develop` and push (`docs.yml` builds on the fleet's
    `kinhin-container` pool, so the daemon must be running). Check `https://kinhin.dev/blog/introducing-kinhin-beta`.
12. **Optional:** add `"v0.0.1-beta-1"` to `website/versions.json` for a versioned docs snapshot.
13. **The first external pull request:** confirm it waits for approval and runs only `fork` and `docs`. The `fork` job
    runs on `macos-26`, which needs Xcode 26+ for Swift 6.2; it has not run yet.
