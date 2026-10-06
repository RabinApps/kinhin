# Use kinhin from AI agents

Two ways AI agents meet kinhin: **operating a fleet** on someone's Mac, and **contributing to the kinhin
repository** itself. Both surfaces are deliberate: every read command has a machine-readable document, the CLI
speaks MCP, and the skills under [`skills/`](https://github.com/RabinApps/kinhin/tree/main/skills) teach an agent
the workflows around the commands.

## Skills

Seven skills ship in the repository — one per workflow an agent actually performs:

| Skill | Covers |
| --- | --- |
| `kinhin-install` | Install kinhin and Tart, first-time setup, a rented or remote Mac |
| `kinhin-configure` | Write `config.yaml` safely: accounts, labels, capacity, routes |
| `kinhin-operate` | Start/stop/pause, status, logs, pipeline view, daemon, cleanup, scaling |
| `kinhin-add-forge-account` | Connect a GitHub, GitLab, Gitea/Forgejo, Buildkite, Azure DevOps or Bitbucket account |
| `kinhin-images-toolchains` | `image prepare`, base-image pinning, `.kinhin.yml`, per-project toolchains |
| `kinhin-route-workflow` | Choose and route a workflow to tart, appleContainer, docker or host |
| `kinhin-troubleshoot` | Jobs queued but no VMs, registration failures, token rejected, disk filling |

Each skill's frontmatter `description:` is what your agent's matcher reads, and every command inside it is checked
against `kinhin help` by `scripts/skills-lint.sh` — a skill cannot outlive a renamed command.

**Claude Code** — the repository is a plugin marketplace:

```sh
claude plugin marketplace add RabinApps/kinhin
claude plugin install kinhin@kinhin
```

**Other agents** — copy the `skills/<name>/SKILL.md` files into your agent's skills directory (Claude-format
frontmatter is the de-facto standard).

## MCP: `kinhin mcp`

`kinhin mcp` is an MCP server on stdio: JSON-RPC 2.0, one message per line, stdout carrying protocol only. It
exposes the CLI's non-printing cores, so a tool answer is byte-identical to the command's `--json` document.

```sh
claude mcp add kinhin -- kinhin mcp     # Claude Code
```

```json
{
  "mcpServers": {
    "kinhin": { "command": "kinhin", "args": ["mcp"] }
  }
}
```

| Tool | Returns |
| --- | --- |
| `status` | The `kinhin status --json` document: daemon reachability, running/paused, queue depth |
| `doctor` | Prerequisites, tokens, runtime health and the capacity cap (`kinhin doctor --json`) |
| `setup_status` | The first-run checklist and its `ready` flag |
| `runtimes` | Pools, budget split, health, routes (`noHealth: true` skips probes) |
| `auth_status` | Which forges have a stored token — never the token itself |
| `pipeline` | The live jobs and steps a busy VM runs (needs the daemon; `vm`, `job` filters) |
| `logs` | The log file's tail, redacted for tokens (`limit` caps it) |
| `pause` / `resume` / `stop` | Fleet control through the daemon, with a `message` result |
| `daemon_install` | Install and start the headless LaunchAgent |

**Deliberately not exposed**: `reset`, `cleanup --yes`, `auth set`, and everything that blocks (`start`,
`watch`). The server's `initialize` response carries the same rule as `instructions`, so an agent that never
reads the docs still learns the boundary. A failed tool call answers `isError: true` in-band; protocol errors
are reserved for malformed requests.

## The `--json` CLI surface

For agents that shell out instead of speaking MCP:

- **stdout carries only the document.** Notes and warnings go to stderr, so a redirect or pipe is always
  parseable. Documents are pretty-printed with sorted keys.
- **Exit codes classify the failure**: `0` success, `1` general, `2` usage, `3` config, `4` runtime/engine,
  `5` auth, `130` cancelled (Ctrl-C).
- Two commands use exit `1` as "not ready yet": `kinhin auth status --json` and `kinhin setup-status` exit 1
  until setup is complete (`doctor --json` reports `ready=false` instead of failing).

| Command | Document |
| --- | --- |
| `kinhin status --json` | Fleet status, flattened `paused` / `autoResume` / `queueAgeSeconds` fields |
| `kinhin doctor --json` | Merged diagnostics: host, runtimes, tokens, checklist, capacity |
| `kinhin setup-status --json` | First-run checklist |
| `kinhin auth status --json` | Stored-token state across every configured forge |
| `kinhin runtimes [--json] [--no-health]` | Pools, capacity, budget, health, routes |
| `kinhin pipeline [VM] [--job N] --json` | Live jobs and steps |
| `kinhin config validate --json` | `valid` + parsed facts, or `valid: false` + `error` (exit 3) |
| `kinhin cleanup … --json` | Dry-run report: what a cleanup *would* remove; refuses `--yes` |
| `kinhin workflow test … --json` | Local workflow-run report (exit 1 when a job failed) |
| `kinhin workflow route … --json` | What the route edit did or would do |
| `kinhin toolchains detect … --json` | Detected toolchains and the evidence, with `--write` to save |
| `kinhin image list --json [--runtime <name>]` | Installed images per runtime: name, role, size, last used, who uses them |

## Safety rules for agents

- **Never run `kinhin reset`.** There is no undo and no backup.
- **Ask before `kinhin cleanup --yes`, `kinhin image delete --yes`, `kinhin image prune --yes`, `kinhin stop` or
  `kinhin daemon uninstall`** on a fleet that may be serving jobs; `kinhin cleanup --json` and
  `kinhin image list --json` are the safe ways to show a human what would go first (plain `kinhin image prune` is the
  same report without the deletion).
- **Host routes are unisolated** — `runtimes route add <pattern> host` requires `--consent` and runs repo code
  directly on the Mac. Don't add one without the user asking.
- **Tokens never appear in any document.** `auth status --json` reports presence and validity only.
- `requeue` and `skip` confirm interactively; pass `--yes` only when the user asked for exactly that.

## Working on the kinhin repository

Agents contributing code should start at [`AGENTS.md`](https://github.com/RabinApps/kinhin/blob/main/AGENTS.md)
(or `CLAUDE.md` for Claude Code): both point at `CONTRIBUTING.md` and the one-shot gate
`scripts/check.sh`.
