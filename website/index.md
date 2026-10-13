---
layout: home

hero:
  name: "kinhin ○"
  text: "Your Mac is your CI. Your repo is your video studio."
  tagline: "Ephemeral runners that scale to your queue, then vanish. Narrated launch videos that rebuild from a file in your repo. Both run on the Mac you already own: no cloud bill for runners, no watermark on videos."
  actions:
    - theme: brand
      text: Get started
      link: /guide/quick-start
    - theme: alt
      text: Make a video
      link: /guide/videos-for-your-project
    - theme: alt
      text: Why does this exist?
      link: /guide/why-kinhin
    - theme: alt
      text: Read the beta announcement
      link: /blog/introducing-kinhin-beta
    - theme: alt
      text: Beta roadmap
      link: /guide/beta-roadmap
    - theme: alt
      text: CLI reference
      link: /cli/commands
    - theme: alt
      text: Sponsor
      link: /guide/support

features:
  - title: In beta
    details: GitHub, Gitea, Forgejo and GitLab CE are supported. Gitea, Forgejo and GitLab CE run end to end on every runtime in kinhin's own test suite; GitHub has run on Tart macOS VMs and apple/container. Buildkite, Azure Pipelines and Bitbucket are planned. <a href="/guide/forges#what-has-been-tested">What has been tested</a> · <a href="/guide/beta-roadmap">Roadmap to v0.1.0</a>
  - title: Parallel jobs, not a queue
    details: Self-hosted runners handle one job at a time. Kinhin scales a fleet of ephemeral runners to your queue so jobs run in parallel. <a href="/guide/why-kinhin">Why kinhin</a>
  - title: Launch videos from a config
    details: "Write the story in YAML. Get a narrated video with your product on screen, captions, music and a vertical cut, then rebuild it whenever you ship. <a href=\"/guide/videos-for-your-project\">Add videos to your project</a>"
  - title: Clean every time
    details: Every job gets a fresh VM or container. The runner deregisters itself afterwards and the instance is deleted — nothing leaks between jobs.
  - title: Multi-forge
    details: GitHub Actions, GitLab CI/CD, Gitea Actions and Forgejo Actions served from one shared pool. Buildkite, Azure Pipelines and Bitbucket Pipelines are planned.
  - title: Multi-runtime
    details: macOS jobs on Tart VMs, Linux jobs on apple/container microVMs, Docker containers, or Tart Linux VMs — each job routed by repo, workflow, or runs-on label.
  - title: Resource-aware
    details: The scaler never exceeds what your Mac can handle. Host CPU, memory, and disk headroom are always reserved, and the budget is partitioned across runtime pools.
  - title: Menu bar or headless
    details: The same engine behind a macOS menu bar app or a LaunchAgent daemon — same config, either way, exactly one fleet.
  - title: One-line install
    details: curl … \| bash from GitHub Releases with sha256 verification, no Gatekeeper dance, and a clean uninstall.
---

<LaunchVideo />

<div style="max-width: 1152px; margin: 32px auto; padding: 0 24px;">

## Your repo is your video studio

Edit a file, rebuild, ship the new cut. The same Mac that runs your CI turns a config in your repo into a narrated video:
a voice, your product on screen, captions and music, built in a container.

```bash
kinhin video init launch                 # a starter config in .kinhin/videos/launch.yml
kinhin video music search "calm piano"   # free CC0 music; `add 1` saves it into the repo
kinhin video build launch                # .kinhin/videos/out/launch/launch.mp4
```

[Add videos to your project](/guide/videos-for-your-project) · [Video gallery](/guide/video-gallery)

::: warning Beta (v0.0.1-beta-1)
Supported: **GitHub, Gitea, Forgejo and GitLab CE**, on Tart macOS and Linux VMs, apple/container, Docker and host
mode. Buildkite, Azure Pipelines and Bitbucket Pipelines are planned for a later release. See [what has been tested](/guide/forges#what-has-been-tested) and the
[roadmap to v0.1.0](/guide/beta-roadmap). Tried one? [Report what you find](https://github.com/RabinApps/kinhin/issues/new/choose).
:::


::: tip Support kinhin
kinhin is free and built by one developer. [Donate or become a sponsor](/guide/support). Also from Rabin Apps: [SupDesk](https://supdesk.app/en).

*Running kinhin in your project? [Add it to the list](/guide/used-by).*

:::

</div>
