# Beta 3 launch checklist (v0.0.1-beta-3, Saturday, October 24, 2026)

Release checklist for [beta-3-launch-post-draft.md](beta-3-launch-post-draft.md). Same rules as the
[beta 2 checklist](beta-2-launch-checklist.md): per gate, keep exactly one of the GATE or FALLBACK block, delete the other with
its markers, and resolve every `TODO(verify:Tn)` and `[MEASURE: ...]`. Scope was decided on 2026-10-24: ship what is done;
the Buildkite, Azure and Bitbucket forge lanes move to beta 4.

## Gates

| Id | Evidence needed | On pass | On fail |
| -- | --------------- | ------- | ------- |
| T1 | `scripts/check.sh` (full) green on the release commit, and CI green on `develop` (the #55 merge failed `DockerEngineIntegrationTests.testEngineWithDockerConfigRunsDockerLifecycle`; explain or fix it). | Keep GATE:T1. | Do not ship. |
| T4 | `scripts/tsan.sh` clean on the release commit. Never `swift test --parallel` under TSan. | Keep GATE:T4. | Keep FALLBACK:T4. A real race blocks the release. |
| T6 | Upgrade beta 2 to beta 3 on a Mac with real state: nothing lost, no `.corrupt-` copy. Then restart the daemon while a job runs on a live Tart VM; the job must finish and the VM not be re-registered. Record in `beta-test-log.md`. | Keep GATE:T6. | Keep FALLBACK:T6. A state-losing upgrade or a disturbed job blocks the release. |
| T8 | A signed rehearsal build installs an update from a local `appcast.xml` (download, EdDSA check, replace, relaunch). Check `bundle-version.sh` orders beta 3 above beta 2. | Keep GATE:T8. | Keep FALLBACK:T8. |
| T9 | App launched in Arabic or Hebrew and one LTR language; Fleet and Settings screenshots checked for truncation and mirroring. | Keep GATE:T9, name the languages. | Keep FALLBACK:T9. |
| G6 | Signed, notarized release published as latest (not prerelease), install URL answers 200, install works on a clean Mac. | Publish. | Mark prerelease, do not publish the site. |

T1, T4, T6 and G6 block the release. T8 and T9 change the post's wording. The end-to-end suite stays "Not yet" until the
`kinhin-e2e` Mac exists; dispatch `e2e.yml` in CI only, never `scripts/e2e.sh` locally.

## Before launch day

1. Confirm CI green on `develop`. Freeze scope.
2. Changelog audit: every user-visible commit since `v0.0.1-beta-2` has a bullet (`git log v0.0.1-beta-2..HEAD --no-merges`),
   duplicate Added and Fixed headings merged.
3. Confirm the `release` environment has `SPARKLE_ED_PRIVATE_KEY` and `KINHIN_SPARKLE_PUBLIC_KEY`, and export both locally.
4. Install beta 2 on the test Mac with real state.
5. Run T1, T4, T6, T8, T9. Resolve the draft, then
   `grep -nE 'GATE:|FALLBACK:|TODO\(verify|MEASURE' docs/plans/beta-3-launch-post-draft.md` must print nothing (remove the leading
   DRAFT comment first). Re-read it line by line against the evidence.
6. Copy the draft to `website/blog/beta-3.md`, keeping the frontmatter. Keep it out of the site build with a `srcExclude` entry
   in `website/.vitepress/config.ts`, and keep the blog index entry commented out, until launch day.
7. Roadmap: make beta-3 "updater, restart safety, localization, video" and add beta-4 "more forges" with the Buildkite, Azure
   and Bitbucket items, multi-account fleets and the e2e runner. Fix `beta-3-plan.md`.
8. `cd website && npx vitepress build`, `bash scripts/docs-lint.sh`, `scripts/docs-sync.sh --check`, `scripts/skills-lint.sh`.
9. Start notarization Wednesday night; Apple's queue can take hours.

## Launch day

1. Release commit: `scripts/changelog.sh promote 0.0.1-beta-3`, `Version.swift`, `scripts/docs-sync.sh`, README blog link,
   `HomeBanners.vue` title and link. Push; CI green.
2. `NOTARY_KEYCHAIN_PROFILE=kinhin SPARKLE_ED_PRIVATE_KEY=… KINHIN_SPARKLE_PUBLIC_KEY=… SPARKLE_TOOLS=~/sparkle scripts/release.sh 0.0.1-beta-3`.
   `[ -s dist/appcast.xml ]` must hold.
3. Publish with `gh release create` as in `docs/releasing.md` ("Local publish"), **five** files including `appcast.xml`.
4. G6 on a clean Mac.
5. Remove the `srcExclude` entry, uncomment the blog index entry, fast-forward `main` to `develop`, push. Check
   `https://kinhin.dev/blog/beta-3`, the older posts, and that `https://kinhin.dev/appcast.xml` lists beta 3.
6. Add `"v0.0.1-beta-3"` to `website/versions.json`. Add a pointer to beta 3 under the beta 2 post's correction.
7. Announce wherever beta 2 was announced.

## Post-publish

| Id | What to run | On pass | On fail |
| -- | ----------- | ------- | ------- |
| G8 | Beta 3 installed; the next release's update installs in app. Not testable before that release. | Follow-up edit in the post and roadmap. | Keep "not exercised"; file the updater log. |
| Nightly | e2e nightly on the `kinhin-e2e` Mac. | "Running nightly since <date>". | Keep "Not yet". |
