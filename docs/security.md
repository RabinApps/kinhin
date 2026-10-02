# Security

What kinhin protects, what it leaves to you, and the settings to turn on if your jobs can include code you don't fully trust (fork PRs, outside contributors).

[← Back to README](../README.md)

## The threat model

Every job runs in a fresh VM or container that is deleted afterwards, but VMs run on the same Mac and (for Tart) the same virtual network. The risks that matter are a job reaching another job's VM, your LAN or your Mac; a job reading the credentials its runner registered with; and a job leaving something behind for a later job. Host mode (`runtime: host`) has no isolation at all: use it for repositories you fully trust.

## If you run untrusted PRs: turn these on

| Setting                                    | Why                                                                                                                                                       |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tart_softnet: true`                       | Runner VMs reach the internet but not each other or your LAN ([setup](runtimes.md#isolating-runner-vms-from-each-other)).                                 |
| `projects[].share_cache: false` (default)   | The shared cache is writable and holds code other jobs execute ([why](toolchains.md)).                                                                    |
| Re-run `kinhin image prepare`              | Images baked by older builds still accept the default `admin` SSH password; a fresh prepare turns password login off.                                     |
| Agent Pools-only Azure DevOps PAT          | Azure agents register with the PAT, so it reaches every runner instance ([forges](forges.md)).                                                            |
| No `runtime: host` for those repositories  | Host mode runs jobs directly on your Mac.                                                                                                                 |

## Check your settings with doctor

`kinhin doctor` (and the app's Diagnostics tab) reports the isolation posture: whether `tart_softnet` is on and `softnet` is installed, which accounts send a token over plain http, and which projects have `share_cache` on. Advisories are warnings and never make the report not-ready; the one hard failure is `tart_softnet: true` without `softnet` installed, because the fleet refuses to start in that state. `kinhin doctor --json` carries the same data under `security` (`softnetEnabled`, `softnetInstalled`, `ok`, `fix`, `insecureHTTPAccounts`, `sharedCacheWritable`, `warnings`).

## What kinhin enforces

- **Guest SSH is key-only.** `image prepare` writes `/etc/ssh/sshd_config.d/000-kinhin-hardening.conf` (no password or keyboard-interactive login) and fails the bake if sshd doesn't honour it. kinhin connects with Tart's key.
- **Registration scripts travel over stdin**, not the command line, so tokens don't appear in `ps` on the host. Inside the guest, the Azure PAT file and the Buildkite token file are deleted as soon as the agent has read them, and the Azure PAT is not exported to the job. (The Azure agent still keeps its own credentials file, and the Buildkite agent holds its token in its environment, so scope those tokens narrowly.)
- **Forge instances use https.** Gitea, Forgejo, GitLab and Azure DevOps instances must be `https://` unless the host is loopback or the account sets `allow_insecure_http: true` ([details](forges.md#plain-http-instances)). Redirects must stay on the same host and may not drop to http; Buildkite and Bitbucket pagination links must match the API host exactly.
- **Config values can't inject shell.** `toolchains.specs`, `brew` and `stacks` entries (in `projects[]` or a `.kinhin.yml`) are limited to letters, digits and `. _ + : / @ = ~ ^ * , -` (no leading `-`), Azure capability values can't carry control characters, and every value is quoted again where it enters a script. Runner version tags from release feeds must look like `v1.2.3`.
- **The daemon socket is private.** It lives in a 0700 directory as a 0600 socket, only the daemon's own user may connect, and at most 32 connections are open at once. `delete_vm` only accepts ids of VMs kinhin created and still tracks.
- **Local files are private.** The support directory, `logs/` and `state/` are 0700 (older installs are tightened on launch) and log, config and fleet-state files are 0600. Tokens live in the Keychain (this-device-only), never in `config.yaml`. The log redactor masks GitHub, GitLab, Bitbucket and Buildkite token formats, `Authorization` / `PRIVATE-TOKEN` headers, JSON-quoted and `NAME_TOKEN=` secrets, credentials inside URLs, and every token kinhin has loaded (so unprefixed Gitea and Azure tokens are masked too). Errors shown in the UI, status and Shortcuts are redacted the same way. `kinhin doctor --bundle` writes a redacted report for bug reports.
- **Host mode is repo-scoped.** The host runner registers at the account's scope, so any workflow in that scope could request it. A config with a `runtime: host` route is refused unless every account is scoped to a single repository (`owner/name`).
- **Updates verify the signer and Gatekeeper.** The updater only accepts `kinhin-<version>-arm64.dmg` for a `vMAJOR.MINOR.PATCH` tag, requires the Developer ID Application signature of the running build's team, asks Gatekeeper (`spctl`) to assess the DMG (notarization, revocation), refuses to update when its own signature cannot be read, only follows redirects within GitHub, and ignores `KINHIN_UPDATE_REPO` in signed builds.
- **The shared cache is pruned safely.** Pruning removes entries relative to a directory descriptor with `O_NOFOLLOW`, so a symlink planted by a job cannot redirect a delete outside the cache.
- **Updates are verified.** See [Updates and installs](install.md#how-updates-and-installs-are-verified).

## Per-project toolchains

A repo's `.kinhin.yml` lets repo contents decide what is installed on your Mac, so it is
treated as untrusted input and bounded ([how it works](toolchains.md#per-project-toolchains)).

- **Opt-in per repo.** The file is ignored unless a `projects:` entry matching the repo sets
  `repo_file: true` (default `false`).
- **Catalog-only, toolchains-only.** The file may only carry `toolchains.specs` and
  `toolchains.stacks`, and every spec must be a tool in kinhin's curated catalog. There is no
  `brew`, no `provision_script`, no `base_image`, and no cache policy from a repo; free-form mise
  backends are rejected. Values pass the same character allowlist as `config.yaml`, and the file
  is capped at 16 KB.
- **Fork PRs ignore the file.** A pull request from a fork never gets its own `.kinhin.yml`
  honored; the file is read from the base repo's default branch instead.
- **`share_cache` exists only per project and is off by default** and forced off for fork PRs. The cache
  subpath is scoped per project so untrusted repos cannot poison each other's cache.
- **Bad files never block the fleet.** A failed fetch or parse is logged and the job runs on the
  global image.

## Telemetry and network calls

kinhin sends no telemetry and has no analytics. It talks only to the forges you configure (and their runner
download hosts), and to GitHub Releases for the once-a-day update check.

## Known limits

- **Guest SSH does not verify host keys.** The host registers runners over SSH to the VM's IP with host key checking off (every VM is a clone of one image, so there is no per-VM key to pin yet). On Tart's default shared network a hostile job in another VM could answer on a booting VM's address and receive its registration token. `tart_softnet: true` closes this; turn it on if any repository you serve runs untrusted code.
- **Registration tokens can be seen by job code in some paths.** With `runners_per_vm > 1` every runner is registered before any starts, so the token is not in `ps` while a job runs. Gitea and host-mode registrations still pass the token as an argument, the Buildkite agent token stays in the agent's environment, and the GitLab runner token file stays on disk until the runner exits. Scope those tokens narrowly.
- **Docker runners keep Docker's default capabilities** (jobs commonly `apt-get` and `sudo`). kinhin adds a pids limit; for stronger isolation prefer Tart VMs.
- **The toolchain cache is shared, writable and trusted by later jobs** when a project's `share_cache` is on. A job can plant content a later job uses, though each project gets its own cache subdirectory. It defaults to off and is always off for fork PRs. Keep it off for untrusted repositories.
- **Any process running as you can control the daemon** over its private socket (stop, token swap). The socket is 0600 in a 0700 directory and checks the peer's uid, not its code signature.
- **The mise installer is not checksum-verified** in Linux image bakes (`mise.run` publishes no digest to pin).

## What stays your responsibility

- Token scopes: give each forge token only what [Forge support](forges.md) says it needs.
- `kinhin auth set` hides the token as you type it. Passing `--token` works but warns, because the value lands in shell history and the process list.
- Base images: the curated defaults are `:latest` tags a registry can republish. Pin one with `kinhin image digest` for reproducible bakes.
- A job still runs as the guest's `admin` user with passwordless `sudo`. Isolation comes from the VM boundary, not from restricting the job inside it.

## For maintainers: CI and releases

- CI runs on a self-hosted Mac that also hosts the fleet, so fork PRs are not run there (`ci.yml` skips them) and the workflow token is read-only.
- The release job needs signing and notarization secrets. Put them in a GitHub **environment** named `release` with required reviewers, and protect `v*` tags, so a pushed tag alone can't reach them. The version is validated as `vMAJOR.MINOR.PATCH` and passed to shell steps through `env:`.
- Actions are pinned to commit SHAs; bump them deliberately.
