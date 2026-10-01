# Security

What kinhin protects, what it leaves to you, and the settings to turn on if your jobs can include code you don't fully trust (fork PRs, outside contributors).

[← Back to README](../README.md)

## The threat model

Every job runs in a fresh VM or container that is deleted afterwards, but VMs run on the same Mac and (for Tart) the same virtual network. The risks that matter are a job reaching another job's VM, your LAN or your Mac; a job reading the credentials its runner registered with; and a job leaving something behind for a later job. Host mode (`runtime: host`) has no isolation at all: use it for repositories you fully trust.

## If you run untrusted PRs: turn these on

| Setting                                    | Why                                                                                                                                                       |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tart_softnet: true`                       | Runner VMs reach the internet but not each other or your LAN ([setup](runtimes.md#isolating-runner-vms-from-each-other)).                                 |
| `toolchains.share_cache: false` (default)  | The shared cache is writable and holds code other jobs execute ([why](toolchains.md)).                                                                    |
| Re-run `kinhin image prepare`              | Images baked by older builds still accept the default `admin` SSH password; a fresh prepare turns password login off.                                     |
| Agent Pools-only Azure DevOps PAT          | Azure agents register with the PAT, so it reaches every runner instance ([forges](forges.md)).                                                            |
| No `runtime: host` for those repositories  | Host mode runs jobs directly on your Mac.                                                                                                                 |

## Check your settings with doctor

`kinhin doctor` (and the app's Diagnostics tab) reports the isolation posture: whether `tart_softnet` is on and `softnet` is installed, which accounts send a token over plain http, and whether `toolchains.share_cache` is on. Advisories are warnings and never make the report not-ready; the one hard failure is `tart_softnet: true` without `softnet` installed, because the fleet refuses to start in that state. `kinhin doctor --json` carries the same data under `security` (`softnetEnabled`, `softnetInstalled`, `ok`, `fix`, `insecureHTTPAccounts`, `sharedCacheWritable`, `warnings`).

## What kinhin enforces

- **Guest SSH is key-only.** `image prepare` writes `/etc/ssh/sshd_config.d/000-kinhin-hardening.conf` (no password or keyboard-interactive login) and fails the bake if sshd doesn't honour it. kinhin connects with Tart's key.
- **Registration scripts travel over stdin**, not the command line, so tokens don't appear in `ps` on the host. Inside the guest, the Azure PAT file and the Buildkite token file are deleted as soon as the agent has read them, and the Azure PAT is not exported to the job. (The Azure agent still keeps its own credentials file, and the Buildkite agent holds its token in its environment, so scope those tokens narrowly.)
- **Forge instances use https.** Gitea, Forgejo, GitLab and Azure DevOps instances must be `https://` unless the host is loopback or the account sets `allow_insecure_http: true` ([details](forges.md#plain-http-instances)). Redirects must stay on the same host and may not drop to http; Buildkite and Bitbucket pagination links must match the API host exactly.
- **Config values can't inject shell.** `toolchains.specs`, `brew` and `stacks` entries are limited to letters, digits and `. _ + : / @ = ~ ^ * , -` (no leading `-`), Azure capability values can't carry control characters, and every value is quoted again where it enters a script. Runner version tags from release feeds must look like `v1.2.3`.
- **The daemon socket is private.** It lives in a 0700 directory as a 0600 socket, only the daemon's own user may connect, and at most 32 connections are open at once. `delete_vm` only accepts ids of VMs kinhin created and still tracks.
- **Local files are private.** The log directory is 0700 and log and fleet-state files are 0600. Tokens live in the Keychain (this-device-only), never in `config.yaml` (debug builds can opt into reading them from environment variables for development; release builds always use the Keychain), and the log redactor masks GitHub, GitLab, Bitbucket and Buildkite token formats and `Authorization` / `PRIVATE-TOKEN` headers.
- **Updates are verified.** See [Updates and installs](install.md#how-updates-and-installs-are-verified).

## What stays your responsibility

- Token scopes: give each forge token only what [Forge support](forges.md) says it needs.
- `kinhin auth set` hides the token as you type it. Passing `--token` works but warns, because the value lands in shell history and the process list.
- Base images: the curated defaults are `:latest` tags a registry can republish. Pin one with `kinhin image digest` for reproducible bakes.
- A job still runs as the guest's `admin` user with passwordless `sudo`. Isolation comes from the VM boundary, not from restricting the job inside it.

## For maintainers: CI and releases

- CI runs on a self-hosted Mac that also hosts the fleet, so fork PRs are not run there (`ci.yml` skips them) and the workflow token is read-only.
- The release job needs signing and notarization secrets. Put them in a GitHub **environment** named `release` with required reviewers, and protect `v*` tags, so a pushed tag alone can't reach them. The version is validated as `vMAJOR.MINOR.PATCH` and passed to shell steps through `env:`.
- Actions are pinned to commit SHAs; bump them deliberately.
