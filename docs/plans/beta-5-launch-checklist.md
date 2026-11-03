# Beta 5 launch checklist (v0.0.1-beta-5)

Release checklist for [the beta 5 post](../../website/blog/beta-5.md). Same shape as the
[beta 4 checklist](beta-4-launch-checklist.md). The post is already written with every live check under "Not yet"; for each
gate you run, move its line to **Run** and say what you saw. Scope: Apple container pools, Docker inside container runners and
the Docker Hub cache, `container.platform: linux/amd64`, `min_idle`, and the layered `image prepare --container` bake. The
Buildkite, Azure and Bitbucket forge lanes, multi-account fleets and the e2e runner moved to beta 6; do not claim them.

## Gates

| Id | Evidence needed | On pass | On fail |
| -- | --------------- | ------- | ------- |
| T1 | `scripts/check.sh` (full) green on the release commit, and CI green on `develop`. | Keep the "Run" line. | Do not ship. |
| T4 | `scripts/tsan.sh` clean on the release commit (pools and the cache touch shared state). Never `swift test --parallel` under TSan. | Move to Run. | A real race blocks the release. |
| T6 | Upgrade beta 4 to beta 5 on a Mac with real state: nothing lost, no `.corrupt-` copy, daemon running after reboot. Record in `beta-test-log.md`. | Move to Run. | A state-losing upgrade blocks the release. |
| T8 | Signed local rehearsal only (before publishing): a build installs an update from a local `dist/appcast.xml`, and `bundle-version.sh` orders beta 5 above beta 4. The real in-app update from the published release is G8. | Move to Run. | Record it as **Failed** in the post, with what you saw; file the updater log. |
| T14 | Two `container.pools:` with different images and labels: `runs-on: kinhin-container-NAME` lands in the right pool; `kinhin workflow route --pool` agrees; an unbuilt pool is left out; the app's pool editor round-trips. | Move to Run. | Record it as **Failed** with what you saw. A job landing in the wrong pool blocks the release. |
| T15 | `container.docker: true`: a job runs `docker build` and one with `services:`; `registry-cache-kinhin` starts and `kinhin doctor` reports it; `docker: { cache: false }` stops using it. | Move to Run. | Record it as **Failed** with what you saw. |
| T16 | `container.platform: linux/amd64`: bake, a job asking for `x64` lands on it, and a Docker build on it succeeds. | Move to Run. | Record it as **Failed** with what you saw. |
| T17 | `min_idle: 1` on a pool and on a Tart image: the forge's runner list shows an idle runner, and it is replaced after taking a job. | Move to Run. | Record it as **Failed** with what you saw. |
| T18 | `image prepare --container` on a large base: record peak disk use and the builder's cache size; `--clean-builder` removes it. | Add the numbers to the post. | Keep the post's 31 GB / 250 GB claim sourced to the changelog. |
| G6 | Signed, notarized release published as latest (not prerelease), install URL answers 200, install works on a clean Mac. | Publish. | Mark prerelease, do not publish the site. |

"Not yet" means not executed; a check that ran and failed is **Failed** in the post, with the observed result. T1, T4, T6, T14 and G6 block the release. The end-to-end suite stays "Not yet" until the `kinhin-e2e` Mac exists; dispatch
`e2e.yml` in CI only, never `scripts/e2e.sh` locally.

## Before launch day

1. Confirm CI green on `develop`. Freeze scope.
2. Changelog audit: every user-visible commit since `v0.0.1-beta-4` has a bullet (`git log v0.0.1-beta-4..HEAD --no-merges`).
3. Confirm the `release` environment has `SPARKLE_ED_PRIVATE_KEY` and `KINHIN_SPARKLE_PUBLIC_KEY`, and export both locally.
4. Install beta 4 on the test Mac with real state, then run T1, T4, T6 and T14 to T18 (T8 only as a local appcast rehearsal). Update "What has been run" in
   `website/blog/beta-5.md` to match the evidence, line by line, and fix the dateline if the launch date moved.
5. `cd website && npx vitepress build`, `bash scripts/docs-lint.sh`, `scripts/docs-sync.sh --check`, `scripts/skills-lint.sh`.
6. Start notarization the night before; Apple's queue can take hours.

## Launch day

1. `NOTARY_KEYCHAIN_PROFILE=kinhin SPARKLE_ED_PRIVATE_KEY=… KINHIN_SPARKLE_PUBLIC_KEY=… SPARKLE_TOOLS=~/sparkle scripts/release.sh 0.0.1-beta-5`.
   `[ -s dist/appcast.xml ]` must hold.
2. Publish with `gh release create` as in `docs/releasing.md` ("Local publish"), **five** files including `appcast.xml`.
3. G6 on a clean Mac.
4. Do not release the website until the tag is live: `website/versions.json` already lists `v0.0.1-beta-5` and the docs build snapshots it from the tag, so it fails before the tag exists. Once the tag and GitHub release are live, fast-forward `main` to `develop` and push (the site deploys from `main`, so the post goes live with it). Check `https://kinhin.dev/blog/beta-5`, the blog index, and that
   `https://kinhin.dev/appcast.xml` lists beta 5.
5. Announce wherever beta 4 was announced.

## Post-publish

| Id | What to run | On pass | On fail |
| -- | ----------- | ------- | ------- |
| G8 | Beta 4 installed from the published release; update to beta 5 in app. | Edit the post and roadmap. | Record it as **Failed** in the post, with what you saw; file the updater log. |
| Nightly | e2e nightly on the `kinhin-e2e` Mac. | "Running nightly since <date>". | Keep "Not yet". |
