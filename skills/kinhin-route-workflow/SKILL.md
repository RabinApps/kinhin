---
name: kinhin-route-workflow
description: Choose the right kinhin runtime for a workflow (macOS tart vs appleContainer vs Docker vs tart Linux vs host) and route it with one command, `kinhin workflow route`. Use when the user wants a workflow or CI job to run on a different runtime — appcontainer, a Linux container, Docker, a Linux VM, host, or "somewhere cheaper".
---

# Route a workflow to a runtime

**Beta status:** only GitHub Actions with Tart macOS VMs has run for real. Every other
forge/runtime pair is fakes-tested only — say so when the user picks one.

## Rules

- **One command does the work:** `kinhin workflow route <FILE|workflow name> <tart|appleContainer|docker|host>
  [--job NAME] [--dry-run] [--json] [--consent]`. It edits the workflow's `runs-on:` comment-preservingly and,
  *only when routing precedence needs it*, writes an `owner/repo@Workflow` route through the validated config editor;
  a running daemon reloads it live. Never hand-edit `runs-on:` when this command can do it.
- **Always `--dry-run` first** when the change wasn't explicitly approved, then report the before/after and
  `git diff <file>` after applying.
- "appcontainer" or "apple container" means **`appleContainer`** — not Docker, and not the job-level `container:`
  key (that runs the job's steps in a container *inside* the VM, it doesn't choose the pool).
- The command refuses what it can't safely edit: `${{ … }}` expressions, `{group:, labels:}` mappings, and
  reusable-workflow (`uses:`) jobs. Those route through config instead:
  `kinhin runtimes route add <owner/repo>@<Workflow> <runtime>`.
- GitLab, Buildkite and Azure DevOps jobs target by tags/queues/demands, not `runs-on:` — the command refuses them
  and points at `kinhin runtimes route add`. Label forges: GitHub, Gitea, Forgejo, Bitbucket.

## Decide the runtime, in order

1. **Read the workflow's steps, not just its name.**
   - `xcodebuild`, `fastlane`, `codesign`, Keychain, `.app`/`.dmg` → **must be macOS tart VMs** (no Linux runtime
     can run these).
   - `apt-get`, Debian-only binaries, glibc-only toolchains → **Linux** — continue to step 2.
   - An `x86_64`/`amd64` matrix requirement → **Docker** is the only Linux runtime with amd64 (emulated; JIT/Go/
     Java/.NET caveats apply).
   - Nothing architecture- or OS-specific → any runtime; recommend from evidence (step 3).
2. **If the user said "appcontainer" / "apple container" explicitly** → `appleContainer`, don't re-ask; just verify
   setup (step 3) and apply. If they only said "a Linux container" or "somewhere cheaper", ask which Linux type,
   quoting `docs/runtimes.md#choosing-a-linux-runtime`:
   - **apple/container** — the docs' default for Linux CI: VM-grade isolation, no daemon, high density, 8 GB per
     instance; cons: Debian/Ubuntu-based image only, no amd64, never exercised for real (beta).
   - **Docker** — adopt free if Docker Desktop/OrbStack/colima already runs; highest density; amd64 via
     Rosetta/QEMU (JIT caveats); shared kernel.
   - **Tart Linux VM** — full control: your distro, kernel modules, long `sudo`; cons: lowest density, 50 GB per
     instance, needs an ISO or published image.
3. **Recommend from machine-readable state**, never from guesses:
   - `kinhin runtimes --json` → `pools` (configured + labels), `routes`, `defaultRuntime`, `health`, and
     `availability` (what's installed on this Mac: `ready` / `missing:<tool>` / `broken:<reason>`).
   - `kinhin doctor --json` → prerequisites and whether the runtime is prepared.
   The recommended option must be *available on this Mac* (`availability`) and its pool configured (`pools`).
   If two options genuinely fit, present the trade-off and recommend one before writing anything.
4. **Apply:**

   ```bash
   kinhin workflow route "<file>" <runtime> --dry-run   # show the plan
   kinhin workflow route "<file>" <runtime>             # apply
   git diff <file>                                      # report the change
   kinhin workflow test --list                          # verify: jobs now show their runs-on:
   ```

   Report per-job before/after, any route the command reconciled, and the `git diff`. `--json` gives the same
   as a machine-readable object (`jobs`, `route`, `dryRun`).

## Traps

| Trap | What happens / what to do |
| --- | --- |
| Precedence is **workflow route → repo route → `runs-on:` marker → default** | A repo route *outranks* the marker: if `owner/repo` is routed elsewhere, a marker-only edit is ignored and the job queues forever. `workflow route` detects this and writes the overriding workflow route itself — never "fix" it by editing labels by hand. |
| Fleet defaults to containers (a `container:` section with no `runtimes:` section) | Every unrouted job already lands on `appleContainer`. Routing *to tart* needs a config route; the command writes it (tart has no marker). |
| tart has **no marker** | `runs-on:` alone can only send jobs *away* from the default onto marker pools (`kinhin-container`, `kinhin-docker`, `kinhin-host`) — tart targeting off the default is route-only. The command reconciles this. |
| Matrix jobs use `runs-on: ${{ matrix.os }}` | Refused by the editor (it's resolved by the forge at queue time). Route via `kinhin runtimes route add <owner/repo>@<Workflow> <runtime>`. |
| Reusable-workflow jobs (`uses:` with no `runs-on:`) | Refused — writing `runs-on:` would invalidate the job. Route via config. |
| A GitHub-hosted label (`ubuntu-latest`) in the list | Runners AND-match every label, so keeping it would strand the job. The command replaces unmatchable labels with the target pool's exact labels. |
| Org-wide account scope (`scope: acme`) | Route patterns need `owner/repo`. If precedence needs a route the command refuses with the exact `kinhin runtimes route add <owner/repo>@<Workflow> <runtime>` to run first. |
| `host` | Requires `--consent` (jobs run unisolated on this Mac) and every account scoped to a single repository; also `kinhin setup repair host-agent` once. |
| After a route edit, jobs still land wrong | Routes reload live in a daemon, but an *in-process* engine picks the config up on its next poll; check `kinhin runtimes` shows the route, then re-queue with `kinhin requeue <forge>`. |

## More

- [Runtimes & routing](../../docs/runtimes.md) — the three-way Linux comparison and route reference.
- `kinhin workflow route --help` — the command's own usage.
