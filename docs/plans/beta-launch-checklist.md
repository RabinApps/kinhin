# Beta launch checklist (v0.0.1-beta-1, target Saturday, October 31, 2026)

Release checklist for [beta-launch-post-draft.md](beta-launch-post-draft.md). The draft describes the state we want. Every
claim that depends on a result not yet recorded sits inside a gate marker pair. Per gate, decide pass or fail, keep
exactly one block, and delete the other with its markers.

Marker forms in the draft: `GATE:Gn start` / `GATE:Gn end` (target text, keep on pass) and `FALLBACK:Gn start` /
`FALLBACK:Gn end` (what is true without the result, keep on fail). Inline `TODO(verify:Gn)` comments and `[MEASURE: ...]`
placeholders must be resolved too.

## Gates

| Id | Evidence needed | On pass | On fail |
| -- | --------------- | ------- | ------- |
| G1 | `scripts/check.sh` exits 0 on the release commit of `develop`. Green on 2026-10-10 (full run); re-run on the release commit. | Keep `GATE:G1` (AI-development paragraph). | Keep `FALLBACK:G1`. Strongly consider not releasing. |
| G2 | **Passed 2026-10-10, resolved in the draft.** `scripts/e2e.sh --local`: Gitea and Forgejo on Docker and apple/container, pause and resume, daemon-crash reconciliation, the `max_runners` cap, long jobs, forge outage, no-floor scale-down, busy-fleet commands and routing. | Done. | — |
| G3 | **Passed 2026-10-10, resolved in the draft.** GitLab CE 18.4 lifecycle (job in guest, teardown, failing job) on Docker, apple/container, Tart Linux, Tart macOS and host. | Done. | — |
| G4 | One week of the author's own CI on kinhin, with no leaked VMs, containers or registered runners. Evidence: `tart list`, `container list` / `docker ps -a`, the forge's runner list, and `kinhin` logs, checked at the end. | Keep `GATE:G4`. | Keep `FALLBACK:G4` ("Not done"). |
| G5 | `scripts/tsan.sh` completes with no ThreadSanitizer reports. Never run `swift test --parallel` under TSan. | Keep `GATE:G5`. | Keep `FALLBACK:G5`. |
| G6 | Signed, notarized release is published and the installer works: `curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh` downloads, and running it on a clean Mac installs a notarized `kinhin.app` and the CLI. | Keep `GATE:G6`. | Keep `FALLBACK:G6` (no install command in the post). Do not publish with a dead URL. |
| G7 | `kinhin bench` output on the author's Mac: VM boot time, container boot time, throughput at the two-VM cap. Record the Mac model and macOS version. | Keep `GATE:G7` and replace the `[MEASURE: ...]` text with the real numbers and the hardware. | Keep `FALLBACK:G7`. |
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

**Scope freeze: Saturday, October 24.** After that date only fixes, no new gates. Anything not done is "coming in beta-2",
not a thin test.

## Publish steps

1. Resolve every gate above, then check nothing is left:
   `grep -nE 'GATE:|FALLBACK:|TODO\(verify|MEASURE' docs/plans/beta-launch-post-draft.md` must print nothing after you
   have removed the chosen blocks and their markers. Also delete the leading DRAFT comment.
2. Re-read the result against the evidence once, line by line. If a sentence claims something no gate backs, cut it.
3. Copy the resolved draft over `website/blog/introducing-kinhin-beta.md`. Keep the frontmatter; the date line is
   *Saturday, October 31, 2026*.
4. Update the date in `website/blog/index.md` from October 10 to October 31, 2026.
5. Launch scope is GitHub, Gitea, Forgejo and GitLab CE; Buildkite, Azure DevOps and Bitbucket are "planned" everywhere.
   If forge or runtime status changes again, update the same facts in `docs/forges.md` (status table and "What has been
   tested"), `docs/compare.md` (the "Today only ..." line and the kinhin row), `docs/beta-roadmap.md` ("Where we are"),
   `docs/e2e-testing.md` (Status table), and the `MaturityTable` source plus its test
   (`Tests/KinhinKitTests/Core/MaturityTableTests.swift`). Then run `scripts/docs-sync.sh` to regenerate marked blocks;
   do not hand-edit between the markers.
6. Run `cd website && npx vitepress build` (fails on dead links).
7. Run `bash scripts/docs-lint.sh`, then `scripts/check.sh` (use `--fast` while iterating, full run before release).
8. Commit the docs, then tag and publish the release (G6 must already hold). Do not push the draft to the website folder
   earlier than this: `docs/plans/` is excluded from the site on purpose.
