# Beta 4 launch checklist (v0.0.1-beta-4, TODO(verify:Tdate): launch date)

Release checklist for [beta-4-launch-post-draft.md](beta-4-launch-post-draft.md). Same rules as the
[beta 3 checklist](beta-3-launch-checklist.md): per gate, keep exactly one of the GATE or FALLBACK block, delete the other with
its markers, and resolve every `TODO(verify:Tn)` and `[MEASURE: ...]`. Scope: opt-in telemetry, macOS 27 base images, the
beta 3 install fixes, and the breaking Linux-runner label change. The Buildkite, Azure and Bitbucket forge lanes were promised for
beta 4 in the beta 3 post and did not make it; say so in the roadmap and do not claim them.

## Gates

| Id | Evidence needed | On pass | On fail |
| -- | --------------- | ------- | ------- |
| T1 | `scripts/check.sh` (full) green on the release commit, and CI green on `develop`. | Keep GATE:T1. | Do not ship. |
| T4 | `scripts/tsan.sh` clean on the release commit (telemetry added shared state and a start/stop sweep). Never `swift test --parallel` under TSan. | Keep GATE:T4. | Keep FALLBACK:T4. A real race blocks the release. |
| T6 | Upgrade beta 3 to beta 4 on a Mac with real state: nothing lost, no `.corrupt-` copy. Run `kinhin daemon install` from a bare `kinhin` on PATH, reboot, confirm the LaunchAgent points at the real binary and the daemon is running. Record in `beta-test-log.md` (the log has no entry after 2026-10-01). | Keep GATE:T6. | Keep FALLBACK:T6. A state-losing upgrade blocks the release. |
| T8 | A signed rehearsal build installs an update from a local `appcast.xml`; or, after publishing, a Mac on published beta 3 installs beta 4 in the app. Check `bundle-version.sh` orders beta 4 above beta 3. | Keep GATE:T8, say which. | Keep FALLBACK:T8. |
| T10 | Telemetry live: `enabled: true` with a collector (Alloy or OpenTelemetry Collector) and `prometheus_listen`; metrics, traces and logs arrive; `curl 127.0.0.1:PORT/metrics` answers; `kinhin telemetry status` is clean; `kinhin config reload` toggles it without a restart; import `docs/telemetry/kinhin-dashboard.json` and load `kinhin-alerts.yml`, and note what renders. Record in `beta-test-log.md`. | Keep GATE:T10. | Keep FALLBACK:T10. |
| T11 | Pull and boot `macos-golden-gate-base` (or `-xcode`) under Tart and run a job on it. Also try a `@sha256:` pinned reference. | Keep GATE:T11. | Keep FALLBACK:T11. |
| T12 | A live job with `runs-on: kinhin-container` (and `kinhin-docker` if installed) lands on the Linux runner, and a `macos` job does not. Also check `fleet_labels: false`. | Keep GATE:T12. | Keep FALLBACK:T12. A macOS job landing on a Linux runner blocks the release. |
| T13 | On Tart: `vm.cpu` and `vm.memory_gb` visible in `tart get` on a fresh clone; `warm_pool: 1` holds one VM through a clone and boot; `image delete` continues past a failure. | Keep GATE:T13. | Keep FALLBACK:T13. |
| G6 | Signed, notarized release published as latest (not prerelease), install URL answers 200, install works on a clean Mac. | Publish. | Mark prerelease, do not publish the site. |

T1, T4, T6, T12 and G6 block the release. T8, T10, T11 and T13 change the post's wording. The end-to-end suite stays "Not yet"
until the `kinhin-e2e` Mac exists; dispatch `e2e.yml` in CI only, never `scripts/e2e.sh` locally.

## Before launch day

1. Confirm CI green on `develop`. Freeze scope.
2. Changelog audit: every user-visible commit since `v0.0.1-beta-3` has a bullet (`git log v0.0.1-beta-3..HEAD --no-merges`),
   duplicate Added and Fixed headings merged. The `Unreleased` section needs an **Upgrading** entry for the label change and
   `fleet_labels: false`, as beta 3 had.
3. Confirm the `release` environment has `SPARKLE_ED_PRIVATE_KEY` and `KINHIN_SPARKLE_PUBLIC_KEY`, and export both locally.
4. Install beta 3 on the test Mac with real state.
5. Run T1, T4, T6, T8, T10, T11, T12, T13. Resolve the draft, then
   `grep -nE 'GATE:|FALLBACK:|TODO\(verify|MEASURE' docs/plans/beta-4-launch-post-draft.md` must print nothing (remove the leading
   DRAFT comment first). Re-read it line by line against the evidence. Fill in the dateline.
6. Copy the draft to `website/blog/beta-4.md`, keeping the frontmatter. Keep it out of the site build with a `srcExclude` entry
   in `website/.vitepress/config.ts`, and keep the blog index entry commented out, until launch day.
7. Roadmap: make beta-4 "telemetry, macOS 27 images, install fixes, Linux label split" and move the Buildkite, Azure and
   Bitbucket items, multi-account fleets and the e2e runner to beta 5. Fix `beta-3-plan.md` if it still promises forges for beta 4.
8. `cd website && npx vitepress build`, `bash scripts/docs-lint.sh`, `scripts/docs-sync.sh --check`, `scripts/skills-lint.sh`.
9. Start notarization the night before; Apple's queue can take hours.

## Launch day

1. Release commit: `scripts/changelog.sh promote 0.0.1-beta-4`, `Version.swift`, `scripts/docs-sync.sh`, README blog link,
   `HomeBanners.vue` title and link. Push; CI green.
2. `NOTARY_KEYCHAIN_PROFILE=kinhin SPARKLE_ED_PRIVATE_KEY=… KINHIN_SPARKLE_PUBLIC_KEY=… SPARKLE_TOOLS=~/sparkle scripts/release.sh 0.0.1-beta-4`.
   `[ -s dist/appcast.xml ]` must hold.
3. Publish with `gh release create` as in `docs/releasing.md` ("Local publish"), **five** files including `appcast.xml`.
4. G6 on a clean Mac.
5. Remove the `srcExclude` entry, uncomment the blog index entry, fast-forward `main` to `develop`, push. Open PRs against
   `develop` unless told otherwise. Check `https://kinhin.dev/blog/beta-4`, the older posts, and that
   `https://kinhin.dev/appcast.xml` lists beta 4.
6. Add `"v0.0.1-beta-4"` to `website/versions.json`. Add a pointer to beta 4 under the beta 3 post's forges section, which
   promised forges for beta 4.
7. Announce wherever beta 3 was announced.

## Post-publish

| Id | What to run | On pass | On fail |
| -- | ----------- | ------- | ------- |
| G8 | Beta 3 installed from the published release; update to beta 4 in app (download, EdDSA check, replace, relaunch). | Follow-up edit in the post (T8) and roadmap. | Keep "not exercised"; file the updater log. |
| Telemetry | A week of a real fleet exporting to a collector; alert rules fire on a stopped daemon. | "Running since <date>". | Keep the beta caveat; file issues. |
| Nightly | e2e nightly on the `kinhin-e2e` Mac. | "Running nightly since <date>". | Keep "Not yet". |
