# Beta launch checklist (v0.0.1-beta-1, target Saturday, October 17, 2026)

Release checklist for [beta-launch-post-draft.md](beta-launch-post-draft.md). The draft describes the state we want. Every
claim that depends on a result not yet recorded sits inside a gate marker pair. Per gate, decide pass or fail, keep
exactly one block, and delete the other with its markers.

Marker forms in the draft: `GATE:Gn start` / `GATE:Gn end` (target text, keep on pass) and `FALLBACK:Gn start` /
`FALLBACK:Gn end` (what is true without the result, keep on fail). Inline `TODO(verify:Gn)` comments and `[MEASURE: ...]`
placeholders must be resolved too.

## Gates

| Id | Evidence needed | On pass | On fail |
| -- | --------------- | ------- | ------- |
| G1 | `scripts/check.sh` exits 0 on the release commit of `develop`. It is red today: a `FakeFleetServing` contract test fails because the real engine's `start()` does not report running. Fix the engine or the contract, do not skip the test. | Keep `GATE:G1` (AI-development paragraph). | Keep `FALLBACK:G1`. Strongly consider not releasing. |
| G2 | `scripts/e2e.sh --local` fully green on Gitea AND Forgejo, on Docker AND apple/container, including pause and resume, daemon-crash orphan reconciliation and the `max_runners` cap. Save the output and the date. | Keep every `GATE:G2` block (table rows, e2e section, "Not yet" list, help list). Add any new bugs found to "What running the real thing found" from the run notes. | Keep `FALLBACK:G2` blocks. If only part passed (for example Forgejo yes, apple/container no), edit the rows by hand to name exactly what passed; never keep a row broader than the evidence. |
| G3 | GitLab CE run once end to end: `KINHIN_E2E_HEAVY=1 scripts/e2e.sh --full -- --filter LifecycleTests` (or the GitLab filter) with the lifecycle assertions green. | Keep `GATE:G3`. Remove the `TODO(verify:G3)` comment and fix the "never run" list so GitLab.com stays there. | Keep `FALLBACK:G3`. |
| G4 | One week of the author's own CI on kinhin, with no leaked VMs, containers or registered runners. Evidence: `tart list`, `container list` / `docker ps -a`, the forge's runner list, and `kinhin` logs, checked at the end. | Keep `GATE:G4`. | Keep `FALLBACK:G4` ("Not done"). |
| G5 | `scripts/tsan.sh` completes with no ThreadSanitizer reports. Never run `swift test --parallel` under TSan. | Keep `GATE:G5`. | Keep `FALLBACK:G5`. |
| G6 | Signed, notarized release is published and the installer works: `curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh` downloads, and running it on a clean Mac installs a notarized `kinhin.app` and the CLI. | Keep `GATE:G6`. | Keep `FALLBACK:G6` (no install command in the post). Do not publish with a dead URL. |
| G7 | `kinhin bench` output on the author's Mac: VM boot time, container boot time, throughput at the two-VM cap. Record the Mac model and macOS version. | Keep `GATE:G7` and replace the `[MEASURE: ...]` text with the real numbers and the hardware. | Keep `FALLBACK:G7`. |
| G8 | In-app updater: not testable until a second release exists. Not a pass or fail gate. | Nothing to change: the table row stays "Not exercised (this is the first release)". | Same. |

## Publish steps

1. Resolve every gate above, then check nothing is left:
   `grep -nE 'GATE:|FALLBACK:|TODO\(verify|MEASURE' docs/plans/beta-launch-post-draft.md` must print nothing after you
   have removed the chosen blocks and their markers. Also delete the leading DRAFT comment.
2. Re-read the result against the evidence once, line by line. If a sentence claims something no gate backs, cut it.
3. Copy the resolved draft over `website/blog/introducing-kinhin-beta.md`. Keep the frontmatter; the date line is
   *Saturday, October 17, 2026*.
4. Update the date in `website/blog/index.md` from October 10 to October 17, 2026.
5. If forge or runtime status changed (G2, G3), update the same facts in `docs/forges.md` (status table and "What has been
   tested"), `docs/compare.md` (the "Today only ..." line and the kinhin row), `docs/beta-roadmap.md` ("Where we are"),
   `docs/e2e-testing.md` (Status table), and the `MaturityTable` source plus its test
   (`Tests/KinhinKitTests/Core/MaturityTableTests.swift`). Then run `scripts/docs-sync.sh` to regenerate marked blocks;
   do not hand-edit between the markers.
6. Run `cd website && npx vitepress build` (fails on dead links).
7. Run `bash scripts/docs-lint.sh`, then `scripts/check.sh` (use `--fast` while iterating, full run before release).
8. Commit the docs, then tag and publish the release (G6 must already hold). Do not push the draft to the website folder
   earlier than this: `docs/plans/` is excluded from the site on purpose.
