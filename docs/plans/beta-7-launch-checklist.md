# Beta 7 launch checklist (v0.0.1-beta-7)

Release checklist for [the beta 7 post](../../website/blog/beta-7.md). Same shape as the
[beta 6 checklist](beta-6-launch-checklist.md). The post is already written with every live check under "Not yet"; for each
gate you run, move its line to **Run** and say what you saw. Scope: the redesigned app, storage paths, pool on/off, several
alert webhooks, the Docker build cache and Docker Hub cache repair, and `min_idle` floors on reload. The Buildkite, Azure and
Bitbucket forge lanes, multi-account fleets and the e2e runner moved to beta 8; do not claim them. Launch date: Wednesday,
November 18, 2026; move the post's dateline if the gates slip.

## Gates

| Id | Evidence needed | On pass | On fail |
| -- | --------------- | ------- | ------- |
| T1 | `scripts/check.sh` (full) green on the release commit, and CI green on `develop`. | Keep the "Run" line. | Do not ship. |
| T4 | `scripts/tsan.sh` clean on the release commit (pool switches, reload and the storage preflight touch shared state). Never `swift test --parallel` under TSan. | Move to Run. | A real race blocks the release. |
| T6 | Upgrade beta 6 to beta 7 on a Mac with real state: nothing lost, no `.corrupt-` copy, daemon running after reboot. Record in `beta-test-log.md`. | Move to Run. | A state-losing upgrade blocks the release. |
| T8 | Signed local rehearsal only (before publishing): a build installs an update from a local `dist/appcast.xml`, and `bundle-version.sh` orders beta 7 above beta 6. The real in-app update from the published release is G8. | Move to Run. | Record it as **Failed** in the post, with what you saw; file the updater log. |
| T19 | Alert webhooks: two webhooks with different `events` pointed at a local `http://127.0.0.1` listener and one real Slack, Discord or ntfy endpoint. Each gets only its own events, once; `kinhin alerts test --webhook NAME` tests one; a legacy single `webhook:` still works as `default`. | Move to Run. | Record it as **Failed** with what you saw. |
| T20 | Storage paths: `tart_home` and `container_app_root` on an external volume. A volume mounted without ownership is refused and nothing falls back to the internal disk; `kinhin doctor` reports each path. | Move to Run. | Record it as **Failed** with what you saw. |
| T21 | Pools: `enabled: false` drains a pool and hides it from Fleet; a `min_idle` change applies on reload without an engine restart. | Move to Run. | A reload that tears down running jobs blocks the release. |
| T22 | Docker build cache (`docker: { build_cache: true }`): a second job reuses the first job's layers, and two runners never share a volume. A broken Docker Hub cache entry is repaired and `kinhin doctor` reports it. | Move to Run. | Record it as **Failed** with what you saw. |
| G6 | Signed, notarized release published as latest (not prerelease), install URL answers 200, install works on a clean Mac. | Publish. | Mark prerelease, do not publish the site. |

"Not yet" means not executed; a check that ran and failed is **Failed** in the post, with the observed result. T1, T4, T6, T21
and G6 block the release. The end-to-end suite stays "Not yet" until the `kinhin-e2e` Mac exists; dispatch `e2e.yml` in CI
only, never `scripts/e2e.sh` locally.

## Before launch day

1. Merge the release PR into `develop`, confirm CI green, freeze scope.
2. Changelog audit: every user-visible commit since `v0.0.1-beta-6` has a bullet (`git log v0.0.1-beta-6..HEAD --no-merges`).
3. Confirm the `release` environment has `SPARKLE_ED_PRIVATE_KEY` and `KINHIN_SPARKLE_PUBLIC_KEY`, and export both locally.
4. Install beta 6 on the test Mac with real state, then run T1, T4, T6 and T21, then T19 to T22 as time allows (T8 only as a
   local appcast rehearsal). Update "What has been run" in `website/blog/beta-7.md` to match the evidence, line by line.
5. `cd website && npx vitepress build`, `bash scripts/docs-lint.sh`, `scripts/docs-sync.sh --check`, `scripts/skills-lint.sh`.
6. After the last edit to the post, run T1 and T4 again on the exact commit you will tag. Record the results and that commit's SHA in the release notes or the release PR, not in the post: editing the post makes a new commit, so the tagged commit would no longer be the tested one. Move the post's "What has been run" lines after tagging.
7. Start notarization as early as possible; Apple's queue can take hours.

## Launch day

0. Check out the `develop` commit that passed T1 (the one from step 6 above).
1. `NOTARY_KEYCHAIN_PROFILE=kinhin SPARKLE_ED_PRIVATE_KEY=… KINHIN_SPARKLE_PUBLIC_KEY=… SPARKLE_TOOLS=~/sparkle scripts/release.sh 0.0.1-beta-7`.
   `[ -s dist/appcast.xml ]` must hold.
2. Confirm `git rev-parse HEAD` equals the `develop` commit that passed T1, then publish with `gh release create` as in `docs/releasing.md` ("Local publish"), **five** files including `appcast.xml`.
3. G6 on a clean Mac. `docs.yml` also runs on a successful `Release` run and copies the latest `appcast.xml` to kinhin.dev, so
   the update feed can go live as soon as the release is published. Before step 2, add a required reviewer to the
   `github-pages` environment and approve the deploy only after G6 passes (keep the `workflow_run` trigger). If G6 fails,
   reject the deploy and mark the release prerelease.
4. Do not release the website until the tag is live: `website/versions.json` already lists `v0.0.1-beta-7` and the docs build
   snapshots it from the tag, so it fails before the tag exists. Once the tag and GitHub release are live, fast-forward `main`
   to `develop` and push (the site deploys from `main`). Check `https://kinhin.dev/blog/beta-7`, the blog index, and that
   `https://kinhin.dev/appcast.xml` lists beta 7.
5. Announce wherever beta 6 was announced.

## Post-publish

| Id | What to run | On pass | On fail |
| -- | ----------- | ------- | ------- |
| G8 | Beta 6 installed from the published release; update to beta 7 in app (with the fleet idle). | Edit the post and roadmap. | Record it as **Failed** in the post, with what you saw; file the updater log. |
| Nightly | e2e nightly on the `kinhin-e2e` Mac. | "Running nightly since <date>". | Keep "Not yet" if it has not run; if it ran and failed, record **Failed** with what you saw. |
