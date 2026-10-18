---
title: How many macOS VMs can run at once?
description: Apple's licence and Virtualization framework allow two macOS guest VMs on one Mac at a time. Here is how kinhin runs more macOS jobs than that.
head:
  - - link
    - rel: canonical
      href: https://kinhin.dev/how-many-macos-vms-can-run-at-once.html
---

# How many macOS VMs can run at once?

Two. Apple's licence and its Virtualization framework limit one Mac to two macOS guest VMs running at the same time. Linux
guests are not subject to that limit. The [why kinhin exists](/guide/why-kinhin) page has the sources.

So a design that runs one VM per runner tops out at two parallel macOS jobs on one Mac, however fast the Mac is.

## How kinhin gets past two

- **Several runners in one VM.** `runners_per_vm` runs more than one runner process inside a single Tart VM, so one VM can
  take several jobs. Size `vm.cpu` and `vm.memory_gb` for the sum of the jobs it will run. See
  [Job density](/guide/scaling#job-density).
- **Linux jobs in containers or Linux VMs.** Linux jobs run in apple/container microVMs, Docker containers, or Tart Linux VMs.
  The two-VM limit applies to macOS guests only. See [Runtimes](/guide/runtimes).

The cap still depends on your Mac. Cores, memory and free disk set how many jobs fit at once, as described in
[How scaling works](/guide/scaling#capacity).

<SearchNextSteps />
