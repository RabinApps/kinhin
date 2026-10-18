---
title: Self-hosted alternative to GitHub-hosted macOS runners
description: Run GitHub Actions macOS jobs on a Mac you own. Each job gets a fresh VM that is deleted afterwards. kinhin is free and open source; you supply the Mac.
head:
  - - link
    - rel: canonical
      href: https://kinhin.dev/self-hosted-alternative-to-github-hosted-macos-runners.html
---

# Self-hosted alternative to GitHub-hosted macOS runners

kinhin runs GitHub Actions macOS jobs on an Apple Silicon Mac that you own. Like GitHub-hosted runners, each job gets a fresh
VM that is deleted when the job ends. The difference is where the Mac lives and who pays for it: kinhin is free and open
source under Apache-2.0, and the hardware, power and upkeep are yours.

## When kinhin fits

- You already have Apple Silicon Macs, or you are willing to buy one, and you run many macOS jobs. A busy Mac can cost less
  than per-minute macOS runner charges.
- You want jobs to run on your own network, with your own toolchains and caches. See [Toolchains](/guide/toolchains).
- You need several jobs at once. kinhin runs a fleet on one Mac; see [How scaling works](/guide/scaling).

## When GitHub-hosted runners fit better

- **You need Intel macOS.** kinhin needs an Apple Silicon Mac.
- **You do not want hardware.** Nothing to buy, power, update or repair.
- **Your jobs are rare.** A Mac that waits for work all day is wasted money.

## Other options

Several hosted macOS services exist, along with other self-hosted tools. The [comparison](/guide/compare) covers them with
what each does well.

To start, follow [How to run GitHub Actions on a self-hosted Mac](/how-to-run-github-actions-on-a-self-hosted-mac).

<SearchNextSteps />
