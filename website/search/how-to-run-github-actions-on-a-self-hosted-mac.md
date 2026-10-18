---
title: How to run GitHub Actions on a self-hosted Mac
description: Run GitHub Actions jobs on your own Apple Silicon Mac. kinhin starts a fresh VM for each queued job and deletes it when the job ends.
head:
  - - link
    - rel: canonical
      href: https://kinhin.dev/how-to-run-github-actions-on-a-self-hosted-mac.html
---

# How to run GitHub Actions on a self-hosted Mac

kinhin turns one Apple Silicon Mac into a fleet of self-hosted GitHub Actions runners. It watches your queue, starts a fresh
macOS VM for each queued job, registers a runner that takes one job, and deletes the VM when the job ends. Your workflow
changes by one line: `runs-on`.

## What you need

- An Apple Silicon Mac on macOS 15 or later, with about 60 GB of free disk. [Hardware and sizing](/guide/hardware) shows how
  much fleet a given Mac can run.
- A GitHub token for the repository or organization, with the permissions listed under [GitHub in Forge support](/guide/forges#github).

## Set it up

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
kinhin setup repair tart
kinhin config init
kinhin auth set
kinhin image prepare && kinhin start
```

In `kinhin config init`, add a `github` account with your repository or organization as its `scope`. Then point a job at
the fleet:

```yaml
jobs:
  build:
    runs-on: [self-hosted, macos, arm64]
```

Run `kinhin watch` to see jobs arrive and runners start.

## What happens to each job

1. The job is queued on GitHub, and kinhin sees it.
2. kinhin starts a linked-clone VM from the base image.
3. The VM registers one runner, which takes the job and no other.
4. When the job ends, the runner is removed and the VM is deleted. Nothing carries over to the next job.

How many jobs run at once depends on your Mac. kinhin caps the fleet from your cores, memory and free disk. See
[How scaling works](/guide/scaling#capacity).

## Before you point a public repository at it

A pull request from a fork can run code on your Mac. Read [Open-source projects](/guide/open-source) before you connect a
public repository.

## Status

GitHub Actions has been run by hand against github.com. Its end-to-end test lane is not run yet. The
[tested-forge table](/guide/forges#what-has-been-tested) has the current state.

<SearchNextSteps />
