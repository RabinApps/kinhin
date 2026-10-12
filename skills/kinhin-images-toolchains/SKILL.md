---
name: kinhin-images-toolchains
description: Build and manage kinhin VM and container images and per-project toolchains - image prepare, base_image pinning, Xcode images, .kinhin.yml, toolchains detect, Linux runtimes. Use when the user needs Xcode, specific tool versions, a Linux runner, or image maintenance.
---

# Images and toolchains

**Beta status:** the Tart macOS and Apple container paths have run for real. The other Linux runtimes (Docker, Tart
Linux) are unit-tested against fakes only. Run `kinhin help image` or `kinhin help toolchains` if a flag here is rejected.

## Images

| Task | Command |
| --- | --- |
| Build the base image | `kinhin image prepare [--provision-script F]` |
| Build a named extra image | `kinhin image prepare --image NAME` (or `--all`) |
| Pre-bake a project image | `kinhin image prepare --project owner/name [--ref R]` |
| Apple container image | `kinhin image prepare --container [--target NAME]` |
| Docker image | `kinhin image prepare --docker [--platform linux/amd64] [--target NAME]` |
| Tart Linux VM | `kinhin image prepare --linux --target NAME [--iso F] [--from [ref]]`, then `--source NAME` to bake the agents in |
| Pin an image by digest | `kinhin image digest <registry>/<repo>:<tag>` |

- `image prepare` is slow and large (about 40 to 60 GB for macOS). Re-run it after upgrading kinhin, and after adding an
  account for a forge whose runner agent is not yet baked in (agents are baked in only if a token for that forge exists).
- `base_image` takes a Tart ref (optionally `@sha256:` pinned) or a local VM name. `kinhin doctor` warns on mutable tags,
  so pin with `image digest`.
- `provision_script` is a host script baked into the image. It is the version pin. A failed run keeps the previous image.
- Extra images go under `images:` (`name`, `base_image`). Names must not start with `kinhin-` or `orchard-`.
- **Xcode is never a toolchain.** Use a Cirrus `-xcode` base image, for example
  `ghcr.io/cirruslabs/macos-tahoe-xcode:latest`:

```yaml
images: [{name: xcode, base_image: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"}]
```

then `kinhin image prepare --image xcode`.

## Toolchains

`kinhin toolchains` shows the catalog. Stacks: flutter, expo, react-native, vercel, cloudflare.

Resolution order for a job: `.kinhin/config.yml` (or the older `.kinhin.yml`) at the job's ref, then `projects[].toolchains` in the config, then the plain
base image.

```yaml
projects:
  - {pattern: "acme/api", toolchains: {specs: ["go@1.23.4","node@22"], stacks: ["flutter@3.24.0"]}, share_cache: false}
  - {pattern: "acme/*", repo_file: true}   # read .kinhin.yml from the repo
```

- Generate a repo file: `kinhin toolchains detect [path] [--json] [--write] [--force]` in a checkout.
- A repo `.kinhin/config.yml` (or `.kinhin.yml`, read when the new one is absent) accepts only catalog `toolchains.specs` and `stacks`, capped at 16 KB. It is honored only on
  GitHub, Gitea/Forgejo and GitLab. Other forges use `projects[].toolchains`.
- Per-job install, and the only option on container and Docker runtimes: `run: kinhin-toolchain install node@22 pnpm`.
- Housekeeping: `kinhin toolchains list-images`, `kinhin toolchains prune [--dry-run]`. See every installed image
  (tart, container, docker) with `kinhin image list [--json]` — `--runtime tart|container|docker` narrows it to one —
  and remove one by name with
  `kinhin image delete <name> [--yes]` — it reports without `--yes` and refuses images runners are using. Sweep the
  whole machine in one confirmed pass with `kinhin image prune [--yes]` — stale derived records plus unused local
  images; configured images, the `base_image` and anything in use are never touched. The same numbers come to you
  without asking: `kinhin doctor` reports per-runtime totals (`imageTotalGB`) and the reclaimable sweep (`imagePrune`),
  and the app's Diagnostics tab shows both rows. Config
  `toolchain_cache` sets `auto_prune`, `max_age_days` (30) and `max_gb` (50). `max_project_images` defaults to 8.

## Linux and host runtimes

| Runtime | Setup | Workflow opt-in |
| --- | --- | --- |
| Apple container | `brew install container && container system start`, `image prepare --container`, a `container:` block, a route | `runs-on: [kinhin-container]` |
| Docker | Install and start Docker yourself (kinhin never starts it), `image prepare --docker`, a `docker:` block | `runs-on: [kinhin-docker]` |
| Tart Linux VM | `image prepare --linux ...`, then `--source NAME` to bake the agents in; a Linux-named image strips the fleet's `macos` label automatically so macOS and Linux Tart VMs can share one fleet | labels |
| Host (unisolated) | `kinhin setup repair host-agent`, route with `consent: true` | `runs-on: [kinhin-host]` |

Route with `kinhin runtimes route add acme/api appleContainer`. Pass `--target <name>` to the container and Docker prepare
commands when routing to a named image. Check readiness with `kinhin setup status` and `kinhin runtimes`. Host mode runs
jobs directly on the Mac, so warn the user before enabling it.

## More

- [Toolchains](https://github.com/RabinApps/kinhin/blob/main/docs/toolchains.md)
- [Runtimes](https://github.com/RabinApps/kinhin/blob/main/docs/runtimes.md)
