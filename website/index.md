---
layout: home

hero:
  name: "kinhin ○"
  text: "The mindful CI"
  tagline: Autoscaling CI runners that live on your Mac — ephemeral, resource-aware, and gone when the job is done. macOS jobs run on Tart VMs; Linux jobs on apple/container microVMs, Docker containers, or Tart Linux VMs.
  actions:
    - theme: brand
      text: Get started
      link: /guide/quick-start
    - theme: alt
      text: Why does this exist?
      link: /guide/why-kinhin
    - theme: alt
      text: CLI reference
      link: /cli/commands

features:
  - title: Real concurrency
    details: Self-hosted runners handle one job at a time. Kinhin scales a fleet of ephemeral runners to your queue so jobs run in parallel. <a href="/guide/why-kinhin">Why kinhin</a>
  - title: Ephemeral by default
    details: Every job gets a freshly cloned VM. The runner deregisters itself afterwards and the VM is deleted — no state leaks between jobs.
  - title: Multi-forge
    details: GitHub Actions, GitLab CI/CD, Gitea Actions, Forgejo, Buildkite, Azure Pipelines and Bitbucket Pipelines served from one shared pool. The Forge abstraction keeps the door open for more.
  - title: Multi-runtime
    details: macOS jobs on Tart VMs, Linux jobs on apple/container microVMs, Docker containers, or Tart Linux VMs — each job routed by repo, workflow, or runs-on label.
  - title: Resource-aware
    details: The scaler never exceeds what your Mac can handle. Host CPU, memory, and disk headroom are always reserved, and the budget is partitioned across runtime pools.
  - title: Menu bar or headless
    details: The same engine behind a macOS menu bar app or a LaunchAgent daemon — same config, either way, exactly one fleet.
  - title: One-line install
    details: curl … \| bash from GitHub Releases with sha256 verification, no Gatekeeper dance, and a clean uninstall.
---
