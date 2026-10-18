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

## Common questions

<p class="lead">Answers to the questions people ask before they try kinhin.</p>

**Mac CI runners**

- [How to run GitHub Actions on a self-hosted Mac](/how-to-run-github-actions-on-a-self-hosted-mac)
- [How to autoscale GitHub Actions runners on a Mac](/how-to-autoscale-github-actions-runners-on-a-mac)
- [How to run GitLab CI jobs on a Mac](/how-to-run-gitlab-ci-jobs-on-a-mac)
- [How to run Gitea or Forgejo Actions on a Mac](/how-to-run-gitea-or-forgejo-actions-on-a-mac)
- [How many macOS VMs can run at once?](/how-many-macos-vms-can-run-at-once)

**Store screenshots**

- [How to take App Store screenshots automatically](/how-to-take-app-store-screenshots-automatically)
- [How to run fastlane screenshots in CI on a Mac](/how-to-run-fastlane-screenshots-in-ci-on-a-mac)
- [How to generate localized app store screenshots](/how-to-generate-localized-app-store-screenshots)

**Launch videos**

- [How to make a product launch video from code](/how-to-make-a-product-launch-video-from-code)

**Alternatives**

- [Self-hosted alternative to GitHub-hosted macOS runners](/self-hosted-alternative-to-github-hosted-macos-runners)
- [Alternatives to Orchard for CI on a Mac](/alternatives-to-orchard-for-ci-on-a-mac)

</div>
