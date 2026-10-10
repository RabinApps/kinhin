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
| No `runtime: host` for those repositories  | Host mode runs jobs directly on your Mac.                                                                                                                 |

## Check your settings with doctor

`kinhin doctor` (and the app's Diagnostics tab) reports the isolation posture: whether `tart_softnet` is on and `softnet` is installed, which accounts send a token over plain http, and which projects have `share_cache` on. Advisories are warnings and never make the report not-ready; the one hard failure is `tart_softnet: true` without `softnet` installed, because the fleet refuses to start in that state. `kinhin doctor --json` carries the same data under `security` (`softnetEnabled`, `softnetInstalled`, `ok`, `fix`, `insecureHTTPAccounts`, `sharedCacheWritable`, `warnings`).

## What kinhin enforces

- **Guest SSH is key-only.** `image prepare` turns off password login in the guest and fails the bake if sshd doesn't honour it.
- **Tokens stay out of reach.** They live in the Keychain (this-device-only), never in `config.yaml`. Registration scripts travel over stdin, so tokens don't appear in `ps` on the host, and the log redactor masks every token format kinhin knows (plus any token it has loaded). `kinhin doctor --bundle` writes a redacted report for bug reports.
- **Forge instances use https.** Gitea, Forgejo and GitLab instances must be `https://` unless the host is loopback or the account sets `allow_insecure_http: true` ([details](forges.md#plain-http-instances)). Redirects must stay on the same host.
- **Config values can't inject shell.** Toolchain entries are limited to a strict character set and quoted again where they enter a script.
- **The daemon socket and local files are private.** The socket is `0600` in a `0700` directory and only your user can connect. The support directory, logs and state are owner-only.
- **Host mode is repo-scoped.** A config with a `runtime: host` route is refused unless every account is scoped to a single repository (`owner/name`).
- **Updates are verified.** The updater requires the same Developer ID signer as the running app and a Gatekeeper check; see [Updates and installs](install.md#how-updates-and-installs-are-verified).
- **The shared cache is pruned safely.** A symlink planted by a job can't redirect a delete outside the cache.

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

- **Tart guest SSH host-key verification has an unverified fallback.** Before registration, kinhin tries to rotate each guest's SSH host keys through Tart's guest-agent channel, then pins the resulting key and requires strict verification. If the guest agent cannot rotate/read the key before the timeout, or the runtime cannot use the guest-agent channel, kinhin records a warning and continues with host-key checking disabled for that instance. On Tart's default shared network a hostile job in another VM could answer on a booting VM's address and receive its registration material. `tart_softnet: true` isolates runner VMs from each other and the LAN, reducing this risk; enable it when serving untrusted code and investigate any host-key fallback warning. For the warning text kinhin emits and how to separate it from the scale-set registration failures that can follow it, see [Troubleshooting scale sets](forges/github.md#troubleshooting-scale-sets).
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

- CI runs on a self-hosted Mac that also hosts the fleet, so fork PRs are not run there and the workflow token is read-only.
- Put the signing and notarization secrets in a GitHub **environment** named `release` with required reviewers, and protect `v*` tags, so a pushed tag alone can't reach them.
- Actions are pinned to commit SHAs; bump them deliberately.
