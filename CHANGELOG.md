# Changelog

## Unreleased

- `kinhin workflow test` no longer reports a pass when it skipped work: matrix jobs, `uses:` actions other than checkout and unsupported `if:` conditions make the result `partial` (new `outcome` and `unsupportedSkips` in `--json`), which exits 1 unless `--lenient` is passed. Each run notes that steps execute directly on this Mac, not isolated.

- `kinhin doctor --check-tokens` probes every configured account's token against its own forge (GitHub, GitLab, Gitea, Forgejo, Buildkite, Azure DevOps, Bitbucket), reports ok/failed per account with the `kinhin auth set` fix, adds `tokenChecks` to `--json` and makes a failed check exit 1. Plain `kinhin doctor` is now fully offline (it no longer mints a GitHub org registration token) and says when tokens were not checked.

- kinhin's own CI runs its docs gates on kinhin: the `docs-lint` job and the VitePress build job use `runs-on: [kinhin-container]` (fork PRs keep the same skip guard as `test`; the Pages deploy job stays on ubuntu-latest), and baked Linux images — Apple container, Docker and tart Linux VMs — now install `git` and `jq` next to the runner agents so `actions/checkout`, `git ls-files` and jq-piping steps work in the container. Existing images gain them after a re-bake: `kinhin image prepare --container` / `--docker`, or `--source <name>` for a tart Linux VM.

- Route a workflow to any runtime with `kinhin workflow route <FILE|name> <tart|appleContainer|docker|host>`: comment-preserving `runs-on:` edits (GitHub-hosted labels replaced with the pool's exact labels; `${{ … }}`, mapping and reusable-workflow jobs refused), automatic `owner/repo@Workflow` route reconciliation only when routing precedence needs it, `--job` / `--dry-run` / `--json`, `--consent` for host. `kinhin runtimes --json` now carries the per-runtime availability sweep, `workflow test --list` shows each job's `runs-on`, and a new `kinhin-route-workflow` skill covers the runtime choice.

- Reset kinhin: `kinhin reset [--scope config|daemon|all] [--yes]` and an Advanced → App **Reset** card wipe local state by scope — config & credentials, the daemon install, or everything (VMs, images, cache, logs included). Both surfaces show the exact plan and confirm twice (plan + typed `reset`); `--yes` is the scripts-only bypass. There is no undo.
- Test GitHub Actions workflow scripts locally with `kinhin workflow test` or the Fleet tab's **Test Workflow…** sheet (host-only; matrices and non-checkout actions are skipped).
- Support and sponsors: `docs/support.md`, GitHub funding links, `kinhin support`, and a Support card and Help menu in the app.
- CLI queue operations: `kinhin requeue <forge> [--yes]` and `kinhin skip <forge> [--yes]` re-queue or skip the fleet's queued jobs on a forge through the daemon (dry-run intent unless `--yes`); the Fleet tab buttons and status-bar menu keep their pending-state / AlertKit UX.

## v0.0.1-beta-1

First public beta.

**Tested for real:** GitHub Actions with Tart macOS VMs.

**Not tested against a real server (unit tests with fakes/stubs only):** Gitea, Forgejo, GitLab, Buildkite,
Azure DevOps, Bitbucket; the apple/container, Docker and host runtimes.

**Not yet exercised:** the in-app updater against a published release (this is the first one).

The path to the full **v0.1.0** release is in [docs/beta-roadmap.md](docs/beta-roadmap.md).

Known limits are listed in [docs/security.md](docs/security.md#known-limits). No telemetry.
