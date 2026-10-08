# Configuration

`~/Library/Application Support/Kinhin/config.yaml` — write the commented starter file with
`kinhin config init`. Key fields:

| Field                                      | Meaning                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `repo`                                     | GitHub scope to serve: `owner/name` for one repo, or a bare org name for org-level runners that serve **every repo in the organization** (PAT needs org runner-admin permission)                                                                                                                                                                             |
| `accounts`                                 | Additional named GitHub/Gitea accounts, each with its own token (`name`, `forge`, `scope`, and `instance` for Gitea) — see [Forges](/guide/forges#multiple-accounts)                                                                                                                                                                                         |
| `labels`                                   | Jobs must request _all_ of these to be picked up                                                                                                                                                                                                                                                                                                             |
| `min_runners` / `max_runners`              | Scaling bounds (in VMs)                                                                                                                                                                                                                                                                                                                                      |
| `runners_per_vm`                           | Runner processes per VM — many-to-one job density (1–8; 1 = one job per VM, most isolated)                                                                                                                                                                                                                                                                   |
| `poll_interval`                            | Seconds between GitHub polls (≥ 5)                                                                                                                                                                                                                                                                                                                           |
| `vm.cpu` / `vm.memory_gb` / `vm.ephemeral` | Per-VM shape                                                                                                                                                                                                                                                                                                                                                 |
| `image`                                    | Tart image cloned per runner (`tahoe-base` after prepare)                                                                                                                                                                                                                                                                                                    |
| `base_image`                               | What `image prepare` starts from: a pre-configured tart image (`ghcr.io/cirruslabs/…`, macOS or Linux), digest-pinned (`ref@sha256:…` — see `kinhin image digest`), or a local VM name (e.g. one made with `image prepare --linux`); absent = the default macOS base. A Linux base turns the Tart pool into [Tart Linux VMs](/guide/runtimes#tart-linux-vms) |
| `provision_script`                         | Host script baked into the image by `image prepare` (your toolchains; see [Toolchains](/guide/toolchains))                                                                                                                                                                                                                                                   |
| `projects`                                 | Per-repo rules (`pattern`, `repo_file`, `toolchains`, `share_cache`): `repo_file: true` lets a repo's `.kinhin.yml` choose its toolchains; `toolchains` declares them here instead. There is no global `toolchains:` (see [Per-project toolchains](/guide/toolchains#per-project-toolchains))                                                                |
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
