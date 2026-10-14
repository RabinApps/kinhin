# Configuration

`~/Library/Application Support/Kinhin/config.yaml` — write the commented starter file with
`kinhin config init`. Key fields:

| Field                                      | Meaning                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `version` | Config schema version (optional, absent = `1`). Unknown keys are an error at version 1; see [Validation](#validation-and-defaults) |
| `accounts` | The forges this fleet serves, each with its own token: `name`, `forge` (`github`, `gitlab`, `gitea`, `forgejo`; `buildkite`, `azuredevops` and `bitbucket` are planned and not supported yet), `scope` (`owner/name` for one repo, or a bare org name for org-level runners that serve **every repo in the organization**; PAT needs org runner-admin permission), and `instance` for self-hosted forges — see [Forges](/guide/forges#multiple-accounts). There is no top-level `repo:` key |
| `labels`                                   | Jobs must request _all_ of these to be picked up                                                                                                                                                                                                                                                                                                             |
| `min_runners` / `max_runners` | Scaling bounds (in VMs). Defaults `0` / `2` |
| `warm_pool` / `warm_max_age_minutes` | Pre-booted, unregistered Tart VMs kept for instant pickup (per image: also `warm_pool` on each `images:` entry), and when to recycle them. Defaults `0` (off) / `60` |
| `runners_per_vm`                           | Runner processes per VM — many-to-one job density (1–8; 1 = one job per VM, most isolated)                                                                                                                                                                                                                                                                   |
| `poll_interval` | Seconds between forge polls (≥ 5, default 20) |
| `vm.cpu` / `vm.memory_gb` / `vm.ephemeral` | Per-VM shape                                                                                                                                                                                                                                                                                                                                                 |
| `image`                                    | Tart image cloned per runner (`tahoe-base` after prepare)                                                                                                                                                                                                                                                                                                    |
| `base_image`                               | What `image prepare` starts from: a pre-configured tart image (`ghcr.io/cirruslabs/…`, macOS or Linux), digest-pinned (`ref@sha256:…` — see `kinhin image digest`), or a local VM name (e.g. one made with `image prepare --linux`); absent = the default macOS base. A Linux base turns the Tart pool into [Tart Linux VMs](/guide/runtimes#tart-linux-vms) |
| `provision_script`                         | Host script baked into the image by `image prepare` (your toolchains; see [Toolchains](/guide/toolchains))                                                                                                                                                                                                                                                   |
| `projects`                                 | Per-repo rules (`pattern`, `repo_file`, `toolchains`, `share_cache`): `repo_file: true` lets a repo's `.kinhin/config.yml` (or older `.kinhin.yml`) choose its toolchains; `toolchains` declares them here instead. There is no global `toolchains:` (see [Per-project toolchains](/guide/toolchains#per-project-toolchains))                                                                |
| `toolchain_cache`                          | Host download-cache expiry: `auto_prune`, `max_age_days` (30), `max_gb` (50). `max_project_images` (8) caps derived images                                                                                                                                                                                                                                   |
| `reserve.cpu` / `reserve.memory_gb`        | Host headroom kept free                                                                                                                                                                                                                                                                                                                                      |
| `reserve.disk_gb`                          | Host disk (GB) kept free (default 10)                                                                                                                                                                                                                                                                                                                        |

Scale-set mode (GitHub, opt-in): an `accounts:` entry may carry `scale_set:` with `name` (the
scale set's name — what workflows put in `runs-on:`; kinhin adds `-container`, `-docker` and `-<image>` sets for the other pools and named images) and `runner_group`
(where the scale set lives; GitHub's built-in group is `Default`, spelled exactly that way, and
kinhin's lookup is case-sensitive). It swaps that account's demand from the REST poll to the
message API — see [Forge support](/guide/forges/github#scale-set-mode-in-kinhin) and
[Troubleshooting scale sets](/guide/forges/github#troubleshooting-scale-sets).

The effective concurrency cap is
`min(max_runners, (cores − reserve.cpu) / vm.cpu, (RAM − reserve.memory_gb) / vm.memory_gb, free_disk / disk_per_vm)` —
`disk_per_vm` is your `disk_gb` when set, else a runtime default (50 GB for Tart VMs, 8 GB for
Linux container slots). The scaler re-checks free disk before every spawn and holds new VMs when
the disk would dip below `reserve.disk_gb` plus one instance's footprint.
`kinhin doctor` prints the result and the binding constraint.

## Validation and defaults

`config.yaml` is validated when it loads, and errors name the key as written in the file
(`vm.memory_gb`, not an internal name).

- **Unknown keys are an error.** A typo such as `max_runner:` is rejected with a suggestion
  (`did you mean 'max_runners'?`) instead of silently falling back to the default. The check covers
  the top level and the nested sections (`vm`, `reserve`, `container`, `docker`, `runtimes`,
  `images`, `accounts`, `projects`, `toolchain_cache`). Top-level keys that start with `x-` are
  ignored, so you can keep notes or YAML anchors there.
- **`version`** is optional and defaults to `1`. A file that declares a newer version than your
  kinhin understands is still read: keys it does not know are logged and ignored, and the keys it
  does know are validated as usual. That lets an older build run a config written for a newer one.
- **Ranges.** `vm_boot_timeout` must be 30–3600 seconds and `token_ttl` 60–3600 seconds, on top of
  the bounds on `poll_interval`, `runners_per_vm` and the resource keys.
- **Defaults** come from one place, so omitting a key and the starter template agree:
  `min_runners: 0`, `max_runners: 2`, `runners_per_vm: 1`, `poll_interval: 20`,
  `vm: {cpu: 4, memory_gb: 8}`, `reserve: {cpu: 2, memory_gb: 4, disk_gb: 10}`.
- **Runtime names** in `runtimes:` (`default`, `budget`, `routes[].runtime`) are `tart`,
  `appleContainer`, `docker` and `host`; anything else is rejected with a suggestion.

### Older configs

The top-level `repo:`, `gitea:` and `forgejo:` keys and the global `toolchains:` section no longer
load; the error names the replacement (an `accounts:` entry, a `projects:` entry, `toolchain_cache:`).
`ConfigMigrator` in KinhinKit translates them as text without writing the file, keeping comments
elsewhere in it.

## Moving to another Mac

Copy a working setup to a second Mac (or a new one) with one command per side:

```bash
kinhin config export kinhin-config.yaml          # on the Mac that has the config
kinhin config import kinhin-config.yaml          # on the new Mac
```

Or in one step over SSH: `kinhin config export | ssh other-mac kinhin config import - --yes`.

- **Tokens are not copied.** They stay in each Mac's Keychain. The import lists every account that has no token on the
  new Mac, with the `kinhin auth set --account NAME` command to store it.
- **Images are not copied.** Each Mac bakes its own; `kinhin setup status` shows which to prepare.
- **Nothing is written until the file validates.** With no config yet the import writes it; an existing config is only
  replaced with `--yes`, and the old one is kept as `config.yaml.bak`.
- The export starts with three `# kinhin export:` comment lines naming the source Mac; the import drops them. A
  `tart_path` that does not exist on the new Mac is reported as a warning.
- A running fleet picks up the new config after you restart the app or the daemon.

## Live reload

Config edits made from the app's **Advanced → Routing** tab (routes, budget split, labels) reach
a running fleet live via `reload_config` — no restart; a running fleet simply re-buckets demand
on its next poll. Routes can also be edited from the terminal:

```bash
kinhin runtimes route add acme/api appleContainer
kinhin runtimes route remove acme/api
```

Every pane edit rewrites only the relevant section of `config.yaml` — comments elsewhere are
preserved — and lands only if the updated file still passes the engine's full config validation.
