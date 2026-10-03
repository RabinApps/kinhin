# Test a GitHub Actions workflow locally

`kinhin workflow test` runs a repository's GitHub Actions workflow scripts on your Mac before you push. It is a host-only convenience tool: it does not start the fleet, a VM, the daemon, or read kinhin's config or forge credentials. The Fleet tab also has **Test Workflow…**, which opens the same runner in a sheet after you choose a workflow file in Finder.

## CLI

Run from a checkout:

```sh
kinhin workflow test
kinhin workflow test --list
kinhin workflow test .github/workflows/ci.yml --job unit-tests
kinhin workflow test --json
```

With no file argument, kinhin uses the only `.yml` or `.yaml` file in `.github/workflows/`. If none exists, or more than one exists, it reports the problem and asks you to provide a file. `--list` shows each job's key, name, step count, and whether it has a matrix. `--job NAME` runs just that job, without its `needs:` jobs. `--json` suppresses progress output and emits the final report as JSON.

Exit codes follow the CLI convention: `0` all jobs succeeded, `1` a workflow run failed, `2` invalid command-line usage, `3` missing/invalid workflow YAML, and `130` cancellation with Ctrl-C.

## Example

Save this as `.github/workflows/local-smoke.yml` in a checkout, then run `kinhin workflow test .github/workflows/local-smoke.yml`:

```yaml
name: Local smoke test

env:
  GREETING: Hello

jobs:
  smoke:
    name: Local smoke test
    steps:
      - name: Check the local runner environment
        run: |
          test -d "$GITHUB_WORKSPACE"
          echo "$GREETING, from $RUNNER_OS ($RUNNER_ARCH)"
```

The same complete workflow is checked in as [`Tests/Fixtures/workflow-local-smoke.yml`](../Tests/Fixtures/workflow-local-smoke.yml); the runner test executes that fixture and checks the output below.

On an Apple Silicon Mac, the step prints `Hello, from macOS (arm64)` and the run ends with a succeeded summary. This example uses only local environment variables; it needs no checkout action, secrets, or network access. To inspect the job before running it, use `kinhin workflow test .github/workflows/local-smoke.yml --list`.

## What runs

Jobs run sequentially in dependency order. Each `run:` step is sent to a local `bash -e -s` (or supported `sh`/`zsh`) process, rooted at the repository directory. Workflow, job, and step `env:` values and `defaults.run.working-directory`/`shell` are applied. `GITHUB_ENV` and `GITHUB_PATH` are temporary files; simple `KEY=VALUE` environment updates and added path lines affect later steps. Each step's output is captured and included in the final report, bounded to its most recent 200,000 characters.

The runner provides a small local environment: `CI`, `GITHUB_ACTIONS`, `GITHUB_WORKSPACE`, `RUNNER_OS=macOS`, and `RUNNER_ARCH=arm64`. It expands <code v-pre>${{ github.workspace }}</code>, <code v-pre>${{ runner.os }}</code>, <code v-pre>${{ runner.arch }}</code>, <code v-pre>${{ env.NAME }}</code>, and <code v-pre>${{ secrets.NAME }}</code>. Secrets are not available locally and expand to empty strings with a warning. The supported simple conditions are `true`, `false`, `success()`, `failure()`, `always()`, and `cancelled()`; unknown expressions or conditions are noted and skipped rather than evaluated.

## Deliberate v1 limits

- Matrix jobs are skipped; matrix values are not expanded.
- `actions/checkout` is a no-op because the working tree is already present. Other `uses:` actions are skipped; third-party actions are not downloaded or executed.
- `GITHUB_ENV` accepts plain `NAME=value` lines; the multiline delimiter form is not supported.
- This runs scripts directly on your Mac, without a VM or container. Only test repositories and scripts you trust. Do not expect the result to exactly match GitHub's hosted runner image or security boundary.
- This is a small subset of Actions syntax, not a general-purpose Actions interpreter. Recheck important behavior in your actual CI environment.

Per-step and per-job `timeout-minutes` are honored, with a 30-minute default per step. Cancelling the CLI with Ctrl-C or pressing **Cancel** in the app terminates the active child process.
