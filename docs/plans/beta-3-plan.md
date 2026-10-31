# Beta 3 plan

## Status update (2026-10-24)

beta-2 shipped on 2026-10-16. The scope below is **superseded**: beta-3 ships what is done (Sparkle updater, restart-recovery
fixes, Ollama healing, video camera and karaoke, seven app languages, Azure experimental) on 2026-10-24, and the forge
live-testing work moves to beta-5. See [beta-3-launch-checklist.md](beta-3-launch-checklist.md) for current beta-3 work. Every section below (Context,
Scope, Recommended order, Verification, Open questions) is historical and left as it was written.

## Context

beta-1 is the latest public release. beta-2 is merged on `develop` and `Version.swift` says `0.0.1-beta-2`, but the
GitHub release is still a **Draft** and the launch checklist ([beta-2-launch-checklist.md](beta-2-launch-checklist.md))
has G6 unmet and T2, T3, T5 not run. Beta 3 starts after beta-2 ships, but the beta-2 leftovers below are real work and
can slip into it.

[docs/beta-roadmap.md](../beta-roadmap.md) defines beta-3 as **"more forges"**. Its exit criterion is: every forge the
docs call supported is live-tested; the rest are clearly labeled planned. This plan follows that reading.

## Scope

### 1. Promote Buildkite, Azure Pipelines and Bitbucket Pipelines (core)

Each forge is implemented and unit-tested already:
- Runner bootstrap: `Sources/KinhinKit/Images/RunnerBootstrap/RunnerBootstrap+{Buildkite,AzureDevOps,Bitbucket}.swift`
- Forge clients and config: `Tests/KinhinKitTests/Forges/{Buildkite,AzureDevOps,Bitbucket}*Tests.swift`
- Registration scripts: `Tests/KinhinKitTests/Images/{Buildkite,Azure,Bitbucket}RegistrationScriptTests.swift`

What is missing is live proof:
- Add a live fixture per forge to the e2e suite (the fixture protocol is ready per [e2e-testing.md](../e2e-testing.md)).
- Run each lane against a real account. Each one needs a token and a throwaway project, which only the owner can create.
- Promote a forge only after its lane passes. Promotion is per forge, so one can ship while another stays planned.

Per-forge promotion touches these places:
- `Sources/KinhinKit/Core/MaturityTable.swift` (`liveTestedForges`, one line) and its test
  `Tests/KinhinKitTests/Core/MaturityTableTests.swift`
- [forges.md](../forges.md) (status table and "What has been tested")
- [compare.md](../compare.md) ("Today only ..." line and the kinhin row)
- [e2e-testing.md](../e2e-testing.md) (status table)
- [beta-roadmap.md](../beta-roadmap.md) ("Where we are")
- `website/` pages that list forges
- Then run `scripts/docs-sync.sh`. Do not hand-edit between the markers.

### 2. Multi-account and mixed-forge fleets on one pool

- Roadmap item. O2 from the beta-1 checklist is still partial: routing by label and repo works (e2e `FeatureTests`), but
  workflow routes do not apply on Gitea/Forgejo, which is a known issue.
- Work: add e2e coverage for one pool with two accounts or two forges, and check the routing and teardown per account.

### 3. Beta-2 carry-overs that block the beta-3 exit criteria

These are not new work, but beta-3 cannot exit without them:
- **`kinhin-e2e` CI runner is not registered.** This blocks the beta-2 T2 and T5 gates and every new forge lane. Register
  it first. It is a shared prerequisite.
- GitHub e2e lane (T5, [e2e-testing.md](../e2e-testing.md)): fixture written, never run.
- Tart Linux warm-VM healing lane: written, never run.
- Gitea 1.25 lifecycle: endpoints probed, lifecycle not run.
- Nightly e2e: commented out in `.github/workflows/e2e.yml` until the Mac is registered.
- In-app updater against a published release (G8).

## Recommended order

1. Ship beta-2 (G6, T4 re-run on the release commit, decide whether T2 and T5 wait). Do not start beta-3 forge work on a
   draft release.
2. Register the `kinhin-e2e` runner, and turn on the nightly schedule once that Mac is up.
3. Add the three forge live fixtures. Run them one at a time, in CI.
4. Multi-account and mixed-fleet e2e.
5. Promote each forge that passes, through the file list in section 1.
6. Write the beta-3 post and checklist, using the beta-2 checklist as the template.

## Verification

- `scripts/check.sh` (full run, not `--fast`) green on the release commit before each promotion.
- `scripts/tsan.sh` if any shared state or actor code changes in the multi-account work.
- e2e runs are dispatched through `.github/workflows/e2e.yml` in CI only. Do not run `scripts/e2e.sh` locally. (The beta-2
  checklist's `--local` form conflicts with this rule.)
- `cd website && npx vitepress build` (fails on dead links) after any docs or website change.
- `scripts/docs-sync.sh --check`, `bash scripts/docs-lint.sh`, `scripts/skills-lint.sh`.

## Open questions for the owner

### Decisions

- **Owner:** Alex Rabin (the repo owner) creates the throwaway accounts or projects for Buildkite, Azure DevOps and
  Bitbucket, and the CI tokens for them.
- **Shipping:** beta-3 ships whichever forges pass their live lane. Each forge is promoted on its own result.
- **rc items:** the soak test and the security known limits may go into beta-3 if they are ready. They are not required
  for beta-3's exit.
- **Small items:** the typo in [compare.md](../compare.md) is fixed. The beta-1 banners in `README.md` and
  `website/.vitepress/theme/HomeBanners.vue` stay as they are until beta-2 ships, because beta-2 launch step 5 changes
  them. Changing them now would break that checklist.
