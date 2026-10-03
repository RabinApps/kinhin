# Changelog

## Unreleased

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
