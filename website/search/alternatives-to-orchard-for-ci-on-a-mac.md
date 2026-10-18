---
title: Alternatives to Orchard for CI on a Mac
description: Orchard orchestrates Tart VMs across Macs but is not a CI integration. Here are the tools that run CI runners on a Mac, and when to pick each.
head:
  - - link
    - rel: canonical
      href: https://kinhin.dev/alternatives-to-orchard-for-ci-on-a-mac.html
---

# Alternatives to Orchard for CI on a Mac

Orchard and kinhin solve different problems, so the right alternative depends on what you need.

**Orchard** is a controller and workers that manage Tart VMs across a cluster of Apple Silicon Macs, with a CLI and a REST API.
It schedules VMs. It does not connect to a CI service, so you still need something that turns a queued CI job into a VM.

**kinhin** is that second part. It watches the queue of your CI service, decides how many runners the queue needs, and places
them on one Mac. It is a CI runner autoscaler, not a cluster.

## If you need CI runners on one Mac

- **kinhin:** queue-driven autoscaling for GitHub Actions, GitLab, Gitea and Forgejo, with a menu bar app and a daemon.
- **runscaler:** a command-line autoscaler for GitHub Actions. Pick it when you use only GitHub and want a small tool.
- **Cilicon and Tartelet:** macOS apps that run ephemeral Tart VMs as runners. Both are smaller in scope.
- **GitLab Runner with the Tart executor:** one VM per job, with concurrency set by hand in `config.toml`.

## If you need many Macs

kinhin manages the Mac it runs on and does not schedule across machines. For a fleet of Macs, an orchestrator is the better
foundation. Orchard is one. Commercial options are Anka Build and Orka, which both run VM fleets with central management.

The [comparison](/guide/compare) has the detail on each tool, with links to their documentation.

<SearchNextSteps />
