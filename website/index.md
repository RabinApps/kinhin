---
layout: home

hero:
  name: "kinhin ○"
  text: "Commit it. Screenshot it. Ship it."
  tagline: "Your Mac is your CI, your screenshot studio and your video studio. Ephemeral runners that scale to your queue, store screenshots in every locale, and launch videos that rebuild from your repo. No cloud bill, no watermark."
  actions:
    - theme: brand
      text: Get started
      link: /guide/quick-start
    - theme: alt
      text: Why kinhin?
      link: /guide/why-kinhin
    - theme: alt
      text: CLI reference
      link: /cli/commands

features:
  - icon: { src: /icons/parallel.svg }
    title: Parallel jobs, not a queue
    details: A fleet of ephemeral runners scales to your queue, so jobs run side by side.
    link: /guide/why-kinhin
    linkText: Why kinhin
  - icon: { src: /icons/clean.svg }
    title: Clean every time
    details: Every job gets a fresh VM or container, deleted when the job ends. Nothing leaks between jobs.
    link: /guide/security
    linkText: Security
  - icon: { src: /icons/forge.svg }
    title: Multi-forge, multi-runtime
    details: GitHub, Gitea, Forgejo and GitLab served from one pool, on Tart, apple/container, Docker or host mode.
    link: /guide/runtimes
    linkText: Runtimes & routing
  - icon: { src: /icons/screenshot.svg }
    title: Store screenshots
    details: One fastlane lane captures localized App Store and Play screenshots in CI.
    link: /guide/mobile-screenshots
    linkText: Store screenshots
  - icon: { src: /icons/video.svg }
    title: Launch videos from a config
    details: Write the story in YAML. Get narration, captions, music and a vertical cut on every release.
    link: /guide/videos-for-your-project
    linkText: Add videos
  - icon: { src: /icons/menubar.svg }
    title: Menu bar or headless
    details: The same engine as a macOS app or a LaunchAgent daemon, with one config and one fleet.
    link: /guide/install
    linkText: Install
---

<div class="home-section">

## Up and running in three commands

```bash
curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash
kinhin config init && kinhin auth set
kinhin image prepare && kinhin start
```

[Read the quick start](/guide/quick-start)

</div>

<div class="home-section">

## Find your way around

<p class="lead">Jump to the part of kinhin you need.</p>

<DocsGrid />

</div>

<div class="home-section">

::: warning Beta (v0.0.1-beta-1)
Supports **GitHub, Gitea, Forgejo and GitLab CE**. See [what has been tested](/guide/forges#what-has-been-tested), the [roadmap to v0.1.0](/guide/beta-roadmap) and the [beta announcement](/blog/introducing-kinhin-beta). [Report what you find](https://github.com/RabinApps/kinhin/issues/new/choose).
:::

::: tip Sponsored by SupDesk
kinhin is sponsored by [SupDesk](https://supdesk.app), the feedback and support console for solo founders, devs and small teams. kinhin is free and built by one developer: [donate or sponsor](/guide/support), or [add your project to the list](/guide/used-by).
:::

</div>
