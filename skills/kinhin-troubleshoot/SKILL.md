---
name: kinhin-troubleshoot
description: Diagnose kinhin problems - jobs queued but no VMs, runner never registers, token rejected, Tart killed on launch, Keychain prompts on a remote Mac, disk filling, config rejected. Use when something in a kinhin fleet is not working.
---

# Troubleshoot kinhin

## Diagnose in this order

1. `kinhin doctor` (add `--json` to parse it). It checks Tart, disk, tokens, isolation posture and the capacity cap —
   and reports each runtime's image disk usage (`imageTotalGB`), with `imagePrune` naming what
   `kinhin image prune` would reclaim when unused images are wasting disk. Doctor is offline by default and only
   says whether a token is *stored*; add `--check-tokens` to probe every account's token against its forge (a revoked
   GitLab/Gitea token otherwise looks fine). A failed check makes doctor not ready and names the `kinhin auth set` fix.
2. `kinhin setup status` and `kinhin auth status`.
3. `kinhin logs -n 200`, and `~/Library/Application Support/Kinhin/logs/kinhin.log`.
4. `kinhin status` and `kinhin pipeline` to see what the fleet thinks is happening.
5. For a bug report: `kinhin doctor --bundle [FILE]` writes a redacted support bundle. Tell the user to review it before
   attaching it to a GitHub issue.

## Symptoms

| Symptom | Likely cause and fix |
| --- | --- |
| `tart: NOT FOUND` | Install Tart (see the `kinhin-install` skill). |
| `tart: INSTALLED BUT KILLED ON LAUNCH` | Un-notarized bottle. `kinhin doctor` prints the exact rollback commands (manual equivalents: `docs/install.md#installing-tart`); then re-run `kinhin doctor`. |
| Jobs queue but no VMs start | The job's `runs-on` (or tags) must include every configured label. The scaler counts only runnable jobs. Check `labels` and the forge's targeting rules. |
| Jobs land on the wrong runtime, or queue forever after a `runs-on:` edit | Precedence is workflow route → repo route → `runs-on:` marker → default: a repo route outranks the marker, and a GitHub-hosted label (`ubuntu-latest`) matches no kinhin runner. `kinhin workflow route <file> <runtime> --dry-run` shows the fix and reconciles a conflicting route — see the `kinhin-route-workflow` skill. |
| VM boots but the runner never registers | The image predates the runner agent or its forge account. Re-run `kinhin image prepare`, then check `kinhin logs -n 200`. |
| Token rejected | Re-run `kinhin auth set [--account NAME]`. Check the token's scopes and repo access (`kinhin auth status`). |
| One account detached | A bad token detaches only that account, with the reason in `status`. Others keep serving. Fix the token. |
| GitHub scale set: second job queued, VM has idle runners | Set `runners_per_vm: 1` and size the Tart pool for two VMs (`kinhin runtimes` shows `cap 2`); restart the daemon when no jobs run. See `docs/forges/github.md`. |
| Config rejected, exit 3 | `kinhin config validate`. Usual causes: old top-level `repo:`/`gitea:`/`forgejo:` keys, `default: host`, `http://` on a self-hosted forge. |
| Fleet refuses to start with `tart_softnet: true` | Install `softnet` and make the resolved binary setuid root (`chown root`, `chmod u+s`). Repeat after each `brew upgrade softnet`. |
| First launch blocked (old or local build) | Right-click Open, or `xattr -cr /Applications/kinhin.app`. Official releases are notarized. |
| Remote Mac keeps prompting for the Keychain | `security unlock-keychain ~/Library/Keychains/login.keychain-db`, enable auto-login, keep FileVault off. |
| Disk filling | Stop the fleet, then `kinhin cleanup --all` (review the report), then `--yes`. For image bloat specifically: the doctor's `prune:` row shows the waste, then `kinhin image prune` (report-only) and `--yes`. |
| Older images allow SSH passwords | Re-run `kinhin image prepare`. A fresh prepare turns that off. |
| I want to run Windows containers or a Windows VM on my Mac | **Windows containers are not possible on macOS.** `microsoft/windows` images need a Windows host kernel (Docker Desktop on Mac has none and no Windows-container mode), and "Windows in a container" projects like `dockur/windows` are full QEMU/KVM VMs that need `/dev/kvm` from a Linux host — Docker Desktop on Mac and Apple's `container` CLI do not provide that, and Macs have no Linux KVM to pass down. If you need Windows CI on a Mac fleet, the realistic local path is a [Windows VM on Apple Silicon](https://github.com/RabinApps/kinhin/blob/main/docs/plans/windows-vms-apple-silicon.md) (substrate-probed, not implemented; gated on a bootable Windows ARM guest source and the per-forge Windows runner story). If you do not need to run Windows locally, route Windows jobs to GitHub-hosted Windows runners (`windows-11-arm` for public repos, or standard Windows hosted runners) with the right `runs-on` label instead.\n
## Rules for the agent

- Read-only commands first. Do not run `cleanup --yes`, `stop` or reinstall steps without telling the user what they
  remove.
- Never ask the user to paste a token into chat. Point them to `kinhin auth set`.
- If the forge is Buildkite, Azure DevOps or Bitbucket, say it is planned and not supported yet. For a supported forge
  (GitHub, Gitea, Forgejo, GitLab CE) that misbehaves, ask for a "Forge report" issue with `kinhin doctor --bundle`.
- If the symptom is not listed, run `kinhin help` for the current commands and read the troubleshooting guide.

## More

- [Troubleshooting guide](https://github.com/RabinApps/kinhin/blob/main/website/guide/troubleshooting.md)
- [Support](https://github.com/RabinApps/kinhin/blob/main/docs/support.md)
