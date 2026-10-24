---
name: kinhin-operate
description: Run and monitor a kinhin fleet - start, stop, pause, status, logs, pipeline view, daemon, cleanup, the healing journal, scaling and capacity. Use when the user asks about fleet status, what kinhin fixed on its own, scaling runners, running kinhin as a daemon, or freeing disk.
---

# Operate kinhin

Run `kinhin help` for the full, current command list. If it disagrees with this page, trust it.

## Exit codes

Scripts can branch on them: `0` success, `1` general, `2` usage (bad command line), `3` config, `4` runtime, `5` auth.
`auth status --json` and `setup status` exit 1 until setup is ready, and `doctor --json` reports `ready=false`.

## Running the fleet

| Command | Use |
| --- | --- |
| `kinhin start` | Run in the foreground |
| `kinhin daemon` | Headless, foreground |
| `kinhin daemon install` / `uninstall` | LaunchAgent (`com.kinhin.daemon`), survives reboots |
| `kinhin pause` / `resume` / `stop` | Control a running fleet |
| `kinhin status [--json]` | Fleet state. JSON includes `daemonRunning`, `paused`, `autoResume`, `pollInterval`, `queueAgeSeconds`. |
| `kinhin watch` | Live stream (prose only, no JSON) |
| `kinhin logs [-n N]` | Recent log lines. The log file is `~/Library/Application Support/Kinhin/logs/kinhin.log`. |
| `kinhin pipeline [VM] [--job NAME\|ID] [--watch] [--json]` | Job and step view. Add `--step N\|NAME` or `--log [--follow]`. Needs the daemon. |
| `kinhin runtimes [--json] [--no-health]` | Runtime availability and health |
| `kinhin heal [--json]` | What the healing agent fixed on its own, fixes waiting for approval, problems only the user can fix. Exits 1 while something waits on the user. Needs the daemon. |

`--json` is supported on `status`, `doctor`, `setup status`, `auth status`, `auth list`, `runtimes`, `pipeline`, `heal`, `workflow test`,
`workflow route`, `toolchains detect`, `config validate` and `cleanup` (report-only; it refuses `--yes`). Stdout
carries only command output, so JSON stays parseable.

## Scaling

- Tune `max_runners`, `runners_per_vm`, `vm.cpu`, `vm.memory_gb` and `reserve` in the config, then `kinhin config validate`
  and `kinhin doctor`. Doctor prints the capacity cap, the binding constraint and each runtime's image disk usage
  (`imageTotalGB`; `imagePrune` names the reclaimable space and the command when unused images are wasting disk).
- macOS allows two concurrent macOS VMs per Mac. Beyond that, raise `runners_per_vm` (1 to 8) or add Macs.
- For several Macs, give each its own label (for example `mac-a`, `mac-b`). Nothing coordinates between Macs.
- Rough sizing: 16 GB gives 1 to 2 VMs of 3 to 4 CPUs and 6 GB; 24 GB gives 2 x (4 CPU / 8 GB); 32 GB gives
  2 x (4 to 6 CPU / 10 to 12 GB). See the hardware guide.

## Cleanup

`kinhin cleanup [--vms] [--image] [--cache] [--all] [--yes] [--json]`

- Without `--yes` it only reports what it would remove. Show the report, then ask before re-running with `--yes`.
- `--json` is that report as a machine document (empty, targets, would-remove lists, summary); it refuses `--yes`.
- Stop the fleet first (`kinhin stop`), or it may delete things in use.
- `--all` removes VMs, images and caches. Uninstall order: stop, `cleanup --all --yes`, `daemon uninstall`, then
  `bash install.sh --uninstall`.

## Reset

`kinhin reset [--scope config|daemon|all] [--yes]`

- Wipes local state irreversibly: `config` = config file + tokens + logs + state + app preferences;
  `daemon` = stops the fleet and removes the LaunchAgent; `all` = everything, including VMs, images
  and the toolchain cache. There is no undo and no backup.
- Never run `kinhin reset` without the user explicitly asking for it, and never add `--yes` yourself:
  interactive runs confirm twice (plan + typed `reset`), and scripts must opt in deliberately.

## Safety

- Do not run `cleanup --yes`, `stop` or `daemon uninstall` on a fleet serving live jobs without confirming with the user.
- Never run `kinhin heal approve` or `kinhin heal dismiss` yourself: show the entry and let the user decide. A fix
  waiting for approval can prune images or reinstall a runtime.
- Untrusted pull requests: keep `tart_softnet: true`, leave `share_cache` off (it is always off for fork PRs), and avoid
  host mode. `kinhin doctor` reports the isolation posture.

## More

- [Scaling](https://github.com/RabinApps/kinhin/blob/main/docs/scaling.md)
- [Hardware](https://github.com/RabinApps/kinhin/blob/main/docs/hardware.md)
- [Security](https://github.com/RabinApps/kinhin/blob/main/docs/security.md)
