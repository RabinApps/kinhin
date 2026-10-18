---
title: How to autoscale GitHub Actions runners on a Mac
description: kinhin starts GitHub Actions runners on your Mac as jobs queue, up to a cap set by the Mac's cores, memory and free disk, then deletes them.
head:
  - - link
    - rel: canonical
      href: https://kinhin.dev/how-to-autoscale-github-actions-runners-on-a-mac.html
---

# How to autoscale GitHub Actions runners on a Mac

Autoscaling means the number of runners follows the queue. When jobs wait, kinhin starts more VMs. When the queue empties,
the VMs are deleted, so nothing idles between builds. You set the ceiling; kinhin works out how many runners the Mac can
actually hold.

Set up the first fleet with [How to run GitHub Actions on a self-hosted Mac](/how-to-run-github-actions-on-a-self-hosted-mac).
This page covers how the fleet grows.

## How big the fleet gets

kinhin's concurrency cap is the smallest of these:

- `max_runners`, the ceiling you set
- your cores after `reserve.cpu`, divided by `vm.cpu`
- your memory after `reserve.memory_gb`, divided by `vm.memory_gb`
- your free disk, divided by the disk each VM needs

Before every spawn, kinhin checks free disk again. It holds new VMs when the disk would drop below `reserve.disk_gb` plus one
VM's footprint, so a burst of jobs cannot fill the disk. `kinhin doctor` prints the cap and which limit is binding.

## Keep VMs warm for faster starts

A cold job pays for a clone and a boot before it runs. Set `warm_pool` to keep booted, unregistered VMs ready, so the next
job skips both. The warm pool is off by default. It covers jobs that use the base image on Tart; jobs with a per-project
image still clone and boot. See [Warm pool](/guide/scaling#warm-pool).

## What autoscaling does not do

kinhin manages the one Mac it runs on. It does not schedule jobs across several Macs. If you have a rack of Macs, read
[the comparison](/guide/compare) before you choose a tool.

<SearchNextSteps />
