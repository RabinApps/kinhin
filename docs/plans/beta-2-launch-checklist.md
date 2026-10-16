# Beta 2 launch checklist (v0.0.1-beta-2, Friday, October 16, 2026)

Release checklist for [beta-2-launch-post-draft.md](beta-2-launch-post-draft.md). The draft describes the state we want.
Every claim that depends on a result not yet recorded sits inside a gate marker pair. Per gate, decide pass or fail, keep
exactly one block, and delete the other with its markers. The same rules as the [beta 1 checklist](beta-launch-checklist.md)
apply.

Marker forms in the draft: `<!-- GATE:Tn start -->` / `<!-- GATE:Tn end -->` (target text, keep on pass) and
`<!-- FALLBACK:Tn start -->` / `<!-- FALLBACK:Tn end -->` (what is true without the result, keep on fail). Inline
`TODO(verify:Tn)` comments and `[MEASURE: ...]` placeholders must be resolved too.

The copy in `website/blog/beta-2.md` must stay identical to the draft until publish. Edit both, or copy the draft over it
once the draft is resolved.

## Status on 2026-10-15

The post resolves each gate to what has run. Nothing below has run beyond what is listed.

| Gate | Result |
| ---- | ------ |
| T1 | Passed. `scripts/release.sh 0.0.1-beta-2` ran `scripts/check.sh` on the release commit (`e82ed18`) before signing, and it passed. |
| T2 | Not run. The suite needs the `kinhin-e2e` CI runner, which is not registered. The post keeps the beta 1 results, marked not re-run. |
| T3 | Partly. The six Gitea-on-Docker healing scenarios passed on 2026-10-14 (recorded in `docs/e2e-testing.md`). The Tart warm-VM case has not run, and the post says so. |
| T4 | Passed on the branch on 2026-10-15, before the last release commits. Not re-run on the release commit. |
| T5 | Not run. The GitHub lane needs the CI runner. |
| T6 | Not run. |
| T7 | Passed for the launch video (size, loudness and captions) and the video unit tests (81 of 81). The smoke tier has not run. |
| G6 | Not met. The release is built and notarized, but not published. The post has no install command. |
| G8 | Not run. It needs the release published first. |

Before publishing, re-run T4 on the release commit, and decide whether T2 and T5 wait for the runner.

## Gates

| Id | Evidence needed | On pass | On fail |
| -- | --------------- | ------- | ------- |
| T1 | `scripts/check.sh` full run (not `--fast`) green on the release commit. `scripts/release.sh` runs it too, unless `--skip-checks` is passed (never do that for a release). | Keep the GATE:T1 block. | Keep FALLBACK:T1. Do not ship. |
| T2 | `scripts/e2e.sh --local` green on the release commit: Gitea and Forgejo on Docker and apple/container, GitLab CE, pause and resume, daemon-crash reconciliation, the `max_runners` cap, forge outage, warm pool, routing, toolchain installs. Resolve the TODO in the draft about the per-image `warm_pool` scenario first. | Keep GATE:T2. If the run covered per-image `warm_pool`, say so in its row; if not, keep that row unit-tested only. | Keep FALLBACK:T2 (beta 1 wording). Remove every "on the release commit" claim. |
| T3 | Healing agent live, four scenarios, each recorded in `docs/plans/beta-test-log.md`: delete a warm VM out of band (the Tart warm-VM lane must actually run), fill the toolchain cache, detach an account, stop the container system. Each must be fixed, and destructive proposals (pruning images, reinstalling a runtime) must still wait for `kinhin heal approve`. The Apple Intelligence path is not one of the four and stays out of the claim. | Keep GATE:T3. | Keep FALLBACK:T3. The post must not say "live-tested" anywhere. |
| T4 | `scripts/tsan.sh` with no ThreadSanitizer reports on the release commit. Never run `swift test --parallel` under TSan. | Keep GATE:T4. | Keep FALLBACK:T4. A real race in healing or warm-pool state blocks the release. |
| T5 | GitHub lane of `scripts/e2e.sh` against a throwaway repository, after the owner's go-ahead for creating the repository and setting `KINHIN_E2E_GITHUB_REPO` and `KINHIN_E2E_GITHUB_TOKEN` (`.github/workflows/e2e.yml`). If the go-ahead or the repository is not ready by Thursday, keep FALLBACK:T5. | Keep GATE:T5. | Keep FALLBACK:T5. |
| T6 | Upgrade from beta 1 on a Mac with real state. Install the beta-1 DMG, run the beta-2 build over its real `fleet.json`, `project-images.json` and repository config (`.kinhin/config.yml`, or the `.kinhin.yml` fallback). Nothing lost, nothing silently reset, and no `.corrupt-` copy appears for a healthy file. | Keep GATE:T6. | Keep FALLBACK:T6. A state-losing upgrade blocks the release. |
| T7 | `video/scripts/test.sh --smoke`, then `kinhin video build` for the launch video (`video/script/launch.json`), then `verify.mjs` (size, loudness, captions, poster, GIF). Frames checked for pointer and hover artefacts. Outputs in `website/public/`. | Keep GATE:T7. Add the home-page player. | Keep FALLBACK:T7. Leave the player out. |
| G6 | Signed, notarized release published as the latest release (not a prerelease), the repository is public, `curl -fsSLI https://github.com/RabinApps/kinhin/releases/latest/download/install.sh` answers 200, and the install command works on a clean Mac. Carried over from beta 1 under the same id. | Keep GATE:G6. | Keep FALLBACK:G6 and mark the release as a prerelease (see launch day, step 4). Do not publish a dead install URL. |

T1 and G6 block the release. T4 (a real race) and T6 (a state-losing upgrade) block it too. T2, T3, T5 and T7 change the
wording of the post, not whether it ships.

### Post-publish checks

These cannot pass before the release is out. The post says "not exercised yet" or "not running yet" until they do. Change
the table row in a follow-up edit once the check passes; do not edit the row before.

| Id | What to run | On pass | On fail |
| -- | ----------- | ------- | ------- |
| G8 | In-app updater: beta 1 is installed on the test Mac, the updater lists `v0.0.1-beta-2` and installs it. `UpdateCheck` lists prereleases only while the running version has a `-`, so beta 1 is eligible. Record the result in `docs/plans/beta-test-log.md`. | Follow-up edit: "Passed on <date>" in the post's table row, and in `docs/beta-roadmap.md`. | Keep "Not exercised yet". File the updater log as a bug. |
| Nightly | The end-to-end suite nightly on the `kinhin-e2e` Mac. The schedule in `e2e.yml` stays commented out until that Mac is registered. | Follow-up edit: "Running nightly since <date>". | Keep "Not running yet". |
| G4 | One-week soak of the author's own CI on kinhin. Cannot finish before this release. | Not in beta 2. | Keep "Not done". |

## Not in scope for beta 2

Buildkite, Azure Pipelines and Bitbucket Pipelines (beta-3), and Windows. The scope is frozen: anything not done is "coming
in beta-3", not a thin test.

Optional gates from beta 1 (O1 to O6) are not part of this release.

## Publish steps (before launch day)

1. Keep the post out of the site build until launch day. `website/.vitepress/config.ts` `srcExclude` lists
   `website/blog/beta-2.md` on this branch, so the site build leaves the draft out. Remove that line in the launch-day site
   commit, together with the blog index entry.
2. Resolve every gate above, then check nothing is left. Remove the leading DRAFT comment from both files first, since it
   names the marker forms. Then:
   `grep -nE 'GATE:|FALLBACK:|TODO\(verify|MEASURE' docs/plans/beta-2-launch-post-draft.md website/blog/beta-2.md` must print
   nothing after you have removed the chosen blocks and their markers.
3. Re-read the result against the evidence once, line by line. If a sentence claims something no gate backs, cut it.
   In particular the healing agent must not read as live-tested unless T3 passed, and the forge section must not name a
   forge fix that has no test.
4. Copy the resolved draft over `website/blog/beta-2.md`. Keep the frontmatter. The date line is
   *Friday, October 16, 2026*.
5. In `website/blog/index.md`, uncomment the beta-2 entry on launch day and keep the beta-1 entry below it. Until then the
   entry is an HTML comment and not linked.
6. Update the same facts in `docs/forges.md` (status table and "What has been tested"), `docs/compare.md` (the "Today only ..."
   line and the kinhin row, if they change), `docs/beta-roadmap.md` ("Where we are" and the beta-2 milestone),
   `docs/e2e-testing.md` (Status table), and the `MaturityTable` source plus its test
   (`Tests/KinhinKitTests/Core/MaturityTableTests.swift`) if a status changes. Then run `scripts/docs-sync.sh`. Do not
   hand-edit between the markers.
7. Changelog: `## Unreleased` has repeated **Added** and **Fixed** blocks. Merge them into one of each before promoting.
   Promotion happens at release time (launch day, step 1).
8. Run `cd website && npx vitepress build` (fails on dead links), `bash scripts/docs-lint.sh`, `scripts/docs-sync.sh --check`,
   and `scripts/skills-lint.sh`.
9. Install beta 1 on the test Mac now, from the beta-1 DMG, so the G8 updater check starts from the real old version.
10. Push `develop`. CI must be green on the fleet.

## Launch day (Friday, October 16)

Start notarization on Thursday night if possible. Apple's queue can take hours (`docs/releasing.md`).

1. **Build the release.** The release commit must be clean, pushed and carry the promoted CHANGELOG heading and
   `Sources/KinhinKit/Core/Version.swift` set to `0.0.1-beta-2`, in one commit. Then:
   `NOTARY_KEYCHAIN_PROFILE=kinhin scripts/release.sh 0.0.1-beta-2`. Check the notary state with
   `scripts/notarize.sh status dist/kinhin-0.0.1-beta-2-arm64.dmg`. If the run is interrupted, resume with
   `scripts/notarize.sh wait` and then `NOTARY_KEYCHAIN_PROFILE=kinhin ./scripts/release-artifacts.sh 0.0.1-beta-2`.
   Check: `dist/` holds the DMG, the CLI zip, `install.sh` and `checksums.txt`, and the script's last screen passes.
2. **Repository visibility.** Public since beta 1. Confirm with `gh repo view RabinApps/kinhin --json visibility`.
3. **Publish the GitHub release** as in `docs/releasing.md` ("Local publish"). Push the commit first, then:
   `awk -v h="## v0.0.1-beta-2" '$0 == h {f=1; next} /^## /{f=0} f' CHANGELOG.md > dist/release-notes.md` and
   `gh release create v0.0.1-beta-2 --target "$(git rev-parse HEAD)" --latest --title "v0.0.1-beta-2" --notes-file dist/release-notes.md dist/kinhin-0.0.1-beta-2-arm64.dmg dist/kinhin-cli-0.0.1-beta-2-arm64.zip dist/install.sh dist/checksums.txt`,
   then `git fetch --tags`. Check: `curl -fsSLI https://github.com/RabinApps/kinhin/releases/latest/download/install.sh`
   answers 200.
4. **Gate G6.** Run the install command on a clean Mac. If it fails, mark the release as a prerelease so `latest` stays on
   beta 1 while you fix it: `gh release edit v0.0.1-beta-2 --prerelease`. Put FALLBACK:G6 back in the post (no install
   command) and do not publish the site.
5. **Banners.** These stay beta-1 until now. Update `README.md`: the blog link on line 11 points to `https://kinhin.dev/blog/beta-2`,
   and the banner on line 13 says `v0.0.1-beta-2` with the same forge list. Update
   `website/.vitepress/theme/HomeBanners.vue`: the title on line 13 becomes `Beta (v0.0.1-beta-2)`, and the announcement link
   on lines 17 and 18 points to `/blog/beta-2`. `website/index.md` had no beta banner when this checklist was written; check
   it again and change it only if it has one.
6. **Publish the site.** Remove the `srcExclude` line for `website/blog/beta-2.md`, uncomment the entry in
   `website/blog/index.md`, and fast-forward `main` to `develop`, then push. `docs.yml` builds on the fleet's
   `kinhin-container` pool, so the daemon must be running. Check `https://kinhin.dev/blog/beta-2` and that
   `https://kinhin.dev/blog/introducing-kinhin-beta` still loads.
7. **Optional:** add `"v0.0.1-beta-2"` to `website/versions.json` for a versioned docs snapshot.
8. **Gate G8.** On the test Mac with beta 1 installed, open the app and check for updates. The updater should find and install
   `v0.0.1-beta-2`. Record the result in `docs/plans/beta-test-log.md`. If it passes, make the follow-up edit described under
   post-publish checks. If it fails, keep "Not exercised yet" and file the log as a bug.
9. **Nightly e2e and G4.** Nothing to do on launch day. Both stay as the post says.
10. **Optional: launch video.** Only if T7 passed. Put `launch.mp4`, `launch.webm` and `launch-poster.png` in
    `website/public/` before step 6. Check that every on-screen claim matches the resolved post.
