# Toolchains & the shared cache

Runner VMs contain exactly what the base image contains — each job gets a fresh linked clone,
so anything a job installs is thrown away when the VM is deleted. There are two ways to get
your toolchains into the image.

## Provision script

`kinhin image prepare` can run **your script** inside the VM once, after the runner agents are
installed; every runner VM then boots with whatever it installed. Write a script — it runs
verbatim as the `admin` user, and a failure aborts the prepare with the previous image left
intact:

```bash
#!/bin/bash
# ~/kinhin/provision.sh — baked into the image by `kinhin image prepare`
brew install wget cmake
mise install go@1.23.4 rust@1.82 java@temurin-21   # exact versions; mise ships in the base image
go version && rustc --version && java -version      # their output is logged as the audit trail
```

```bash
kinhin image prepare --provision-script ~/kinhin/provision.sh
```

- **Versioning is yours.** The script is the pin: every prepare rebuilds from the pristine
  upstream image, so editing the script and re-running prepare is how toolchains change.
- **Audit trail.** End the script with `go version && java -version …` — kinhin logs the
  stdout tail during prepare, recording what went into that image build (see `kinhin logs`).
- **Checklist guard.** A configured script that is missing or empty fails the first-run
  checklist with a one-click fix, so the typo is caught before a 20-minute prepare.
- **Full Xcode?** Don't install it from a script (tens of GB) — point `image:` at Cirrus
  Labs' Xcode images instead.

## Managed toolchains

Instead of writing a script, declare the runtimes you want:

```yaml
toolchains:
  specs: ["go@1.23.4", "node@22", "bun@1.1.27", "deno@2", "java@temurin-17", "dotnet", "uv"]
  brew: ["wget", "cmake", "yamllint"]
  stacks: ["flutter@3.24.0", "expo", "react-native", "vercel", "cloudflare"]
  share_cache: false
  cache:
    auto_prune: true   # sweep after each prepare + daily while the fleet runs
    max_age_days: 30   # entries unused this long are deleted (0 = never)
    max_gb: 50         # LRU eviction beyond this size (0 = unlimited)
```

- **Nothing is installed implicitly.** A stack that needs a runtime (e.g. `vercel` needs node)
  is a **validation error naming the fix** until you select that runtime too.
- **The catalog is advisory.** Unknown specs pass through to mise and unknown brew entries to
  brew — so the long tail works today with zero kinhin code. Run `kinhin toolchains` to see
  the curated list.
- **Verification is the audit trail.** Each tool/stack carries a verify command; the prepare
  aborts with the old image intact if any check fails.

## The shared download cache

`image prepare` always mounts a host-side cache —
`~/Library/Application Support/Kinhin/toolchain-cache/` — into the scratch VM, so repeated
prepares skip re-downloading mise tools, brew bottles, npm packages, and Flutter SDKs. Set
**`share_cache: true`** to mount the same cache into every runner VM: per-job installs
(`npm ci`, `pnpm install`, `mise install`, …) then hit warm cache instead of re-downloading
gigabytes per job.

The cache auto-expires — default 30 days since last use, with LRU eviction past 50 GB — and a
one-hour grace window means a prune can never race a live download. Tune or disable it under
`toolchains.cache`, sweep manually with `kinhin toolchains prune [--dry-run]`, and inspect
size/selections with `kinhin toolchains`.
