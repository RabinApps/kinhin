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
      text: Beta roadmap
      link: /guide/beta-roadmap
    - theme: alt
      text: CLI reference
      link: /cli/commands
    - theme: alt
      text: Sponsor
      link: /guide/support
    - theme: alt
      text: Companies & projects using kinhin
      link: /guide/contributing

features:
  - title: In beta
    details: Only GitHub Actions with Tart macOS VMs has been run for real. Every other forge and runtime is unit-tested only, so expect surprises. <a href="/guide/forges#what-has-been-tested">What has been tested</a> · <a href="/guide/beta-roadmap">Roadmap to v0.1.0</a>
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

<div style="max-width: 1152px; margin: 32px auto; padding: 0 24px;">

::: warning Beta (v0.0.1-beta-1)
Only **GitHub Actions with Tart macOS VMs** has been run for real. Gitea, Forgejo, GitLab, Buildkite, Azure DevOps
and Bitbucket, and the apple/container, Docker and host runtimes, are covered by unit tests against fakes and stubbed
HTTP only. See [what has been tested](/guide/forges#what-has-been-tested) and the
[roadmap to v0.1.0](/guide/beta-roadmap). Tried one? [Report what you find](https://github.com/RabinApps/kinhin/issues/new/choose).
:::


::: tip Support kinhin
kinhin is free and built by one developer. [Donate or become a sponsor](/guide/support). Also from Rabin Apps: [SupDesk](https://supdesk.app/en).

*Companies and projects using [kinhin](https://github.com/RabinApps/kinhin) can add themselves: [Contributing to kinhin](/guide/contributing).*

:::

</div>
