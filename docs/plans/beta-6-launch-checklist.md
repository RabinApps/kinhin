# Beta 6 launch checklist (v0.0.1-beta-6)

Release checklist for [the beta 6 post](../../website/blog/beta-6.md). Same shape as the
[beta 5 checklist](beta-5-launch-checklist.md). The post is already written with every live check under "Not yet"; for each
gate you run, move its line to **Run** and say what you saw. Scope: outbound alerts, the shared `tart list`, one engine per
host, and queued jobs inside in-progress GitHub runs. The Buildkite, Azure and Bitbucket forge lanes, multi-account fleets
and the e2e runner moved to beta 7; do not claim them. Launch date: Friday, November 13, 2026; move the post's dateline if
the gates slip.

## Gates

| Id | Evidence needed | On pass | On fail |
| -- | --------------- | ------- | ------- |
| T1 | `scripts/check.sh` (full) green on the release commit, and CI green on `develop`. | Keep the "Run" line. | Do not ship. |
| T4 | `scripts/tsan.sh` clean on the release commit (the host lock, the list cache and alerts touch shared state). Never `swift test --parallel` under TSan. | Move to Run. | A real race blocks the release. |
| T6 | Upgrade beta 5 to beta 6 on a Mac with real state: nothing lost, no `.corrupt-` copy, daemon running after reboot. Record in `beta-test-log.md`. | Move to Run. | A state-losing upgrade blocks the release. |
| T8 | Signed local rehearsal only (before publishing): a build installs an update from a local `dist/appcast.xml`, and `bundle-version.sh` orders beta 6 above beta 5. The real in-app update from the published release is G8. | Move to Run. | Record it as **Failed** in the post, with what you saw; file the updater log. |
| T19 | Alerts: `alerts:` pointed at a local `http://127.0.0.1` listener and at one real Slack, Discord or ntfy endpoint. A raised and a cleared problem each arrive once; nothing is sent with `alerts:` absent; a dead endpoint leaves the fleet running. | Move to Run. | Record it as **Failed** with what you saw. |
| T20 | Tart: a host with several VMs runs for hours on macOS 27.x; `tart list` calls in the log are at most one per 10 seconds, and the kernel zone map does not grow. A short run stays "Not yet". | Move to Run, with the duration. | Record it as **Failed** with what you saw. |
| T21 | Two engines: start the daemon, then `kinhin start` and the app. Only one engine scales; the second reports the `startup` alert and deletes nothing; a config reload leaves no old listeners and no duplicate runners on the forge. | Move to Run. | A second engine that deletes the owner's instances blocks the release. |
| T22 | GitHub workflow with `needs:` or a matrix: while one job runs, its queued siblings get a runner. | Move to Run. | Record it as **Failed** with what you saw. |
| G6 | Signed, notarized release published as latest (not prerelease), install URL answers 200, install works on a clean Mac. | Publish. | Mark prerelease, do not publish the site. |

"Not yet" means not executed; a check that ran and failed is **Failed** in the post, with the observed result. T1, T4, T6, T21
and G6 block the release. The end-to-end suite stays "Not yet" until the `kinhin-e2e` Mac exists; dispatch `e2e.yml` in CI
only, never `scripts/e2e.sh` locally.

## Before launch day

1. Merge the release PR into `develop`, confirm CI green, freeze scope.
2. Changelog audit: every user-visible commit since `v0.0.1-beta-5` has a bullet (`git log v0.0.1-beta-5..HEAD --no-merges`).
3. Confirm the `release` environment has `SPARKLE_ED_PRIVATE_KEY` and `KINHIN_SPARKLE_PUBLIC_KEY`, and export both locally.
4. Install beta 5 on the test Mac with real state, then run T1, T4, T6 and T21, then T19 to T22 as time allows (T8 only as a
   local appcast rehearsal). Update "What has been run" in `website/blog/beta-6.md` to match the evidence, line by line.
5. `cd website && npx vitepress build`, `bash scripts/docs-lint.sh`, `scripts/docs-sync.sh --check`, `scripts/skills-lint.sh`.
6. Start notarization as early as possible; Apple's queue can take hours.

## Launch day

1. `NOTARY_KEYCHAIN_PROFILE=kinhin SPARKLE_ED_PRIVATE_KEY=… KINHIN_SPARKLE_PUBLIC_KEY=… SPARKLE_TOOLS=~/sparkle scripts/release.sh 0.0.1-beta-6`.
   `[ -s dist/appcast.xml ]` must hold.
2. Publish with `gh release create` as in `docs/releasing.md` ("Local publish"), **five** files including `appcast.xml`.
3. G6 on a clean Mac. `docs.yml` also runs on a successful `Release` run and copies the latest `appcast.xml` to kinhin.dev, so
   the update feed can go live as soon as the release is published. Before step 2, add a required reviewer to the
   `github-pages` environment and approve the deploy only after G6 passes (keep the `workflow_run` trigger). If G6 fails,
   reject the deploy and mark the release prerelease.
4. Do not release the website until the tag is live: `website/versions.json` already lists `v0.0.1-beta-6` and the docs build
   snapshots it from the tag, so it fails before the tag exists. Once the tag and GitHub release are live, fast-forward `main`
   to `develop` and push (the site deploys from `main`). Check `https://kinhin.dev/blog/beta-6`, the blog index, and that
   `https://kinhin.dev/appcast.xml` lists beta 6.
5. Announce wherever beta 5 was announced.

## Post-publish

| Id | What to run | On pass | On fail |
| -- | ----------- | ------- | ------- |
| G8 | Beta 5 installed from the published release; update to beta 6 in app (with the fleet idle). | Edit the post and roadmap. | Record it as **Failed** in the post, with what you saw; file the updater log. |
| Nightly | e2e nightly on the `kinhin-e2e` Mac. | "Running nightly since <date>". | Keep "Not yet". |
