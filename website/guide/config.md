# Configuration

`~/Library/Application Support/Kinhin/config.yaml` — write the commented starter file with
`kinhin config init`. Key fields:

| Field                                      | Meaning                                                                                                                                                                          |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `repo`                                     | GitHub scope to serve: `owner/name` for one repo, or a bare org name for org-level runners that serve **every repo in the organization** (PAT needs org runner-admin permission) |
| `accounts`                                 | Additional named GitHub/Gitea accounts, each with its own token (`name`, `forge`, `scope`, and `instance` for Gitea) — see [Forges](/guide/forges#multiple-accounts)             |
| `labels`                                   | Jobs must request _all_ of these to be picked up                                                                                                                                 |
| `min_runners` / `max_runners`              | Scaling bounds (in VMs)                                                                                                                                                          |
| `runners_per_vm`                           | Runner processes per VM — many-to-one job density (1–8; 1 = one job per VM, most isolated)                                                                                       |
| `poll_interval`                            | Seconds between GitHub polls (≥ 5)                                                                                                                                               |
| `vm.cpu` / `vm.memory_gb` / `vm.ephemeral` | Per-VM shape                                                                                                                                                                     |
| `image`                                    | Tart image cloned per runner (`tahoe-base` after prepare)                                                                                                                        |
| `provision_script`                         | Host script baked into the image by `image prepare` (your toolchains; see [Toolchains](/guide/toolchains))                                                                       |
| `reserve.cpu` / `reserve.memory_gb`        | Host headroom kept free                                                                                                                                                          |
| `reserve.disk_gb`                          | Host disk (GB) kept free (default 10)                                                                                                                                            |

The effective concurrency cap is
`min(max_runners, (cores − reserve.cpu) / vm.cpu, (RAM − reserve.memory_gb) / vm.memory_gb, free_disk / disk_per_vm)` —
`disk_per_vm` is your `disk_gb` when set, else a runtime default (50 GB for Tart VMs, 8 GB for
Linux container slots). The scaler re-checks free disk before every spawn and holds new VMs when
the disk would dip below `reserve.disk_gb` plus one instance's footprint.
`kinhin doctor` prints the result and the binding constraint.

## Live reload

Config edits made from the menu bar's **Runtimes…** pane (routes, budget split, labels) reach
a running fleet live via `reload_config` — no restart; a running fleet simply re-buckets demand
on its next poll. Routes can also be edited from the terminal:

```bash
kinhin runtimes route add acme/api appleContainer
kinhin runtimes route remove acme/api
```

Every pane edit rewrites only the relevant section of `config.yaml` — comments elsewhere are
preserved — and lands only if the updated file still passes the engine's full config validation.
