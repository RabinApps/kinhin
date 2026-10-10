# Compare kinhin to other CI options

What other tools do, what kinhin does, and what kinhin is missing.

[← Back to README](../README.md) · [Why kinhin](why.md)

kinhin is a runner autoscaler: it keeps your existing CI (GitHub Actions, GitLab, Gitea, Forgejo) and feeds it fresh,
isolated Mac capacity. Plenty of other tools solve a neighbouring problem, and
several solve this exact one. This page is a guide to the landscape, not a leaderboard. Most of these tools are good, and
the right pick depends on what you already run and how many machines you have.

## How to read this page

- Facts about other projects were read from their own docs on **2026-10-08** and are linked at the end. Projects change,
  so check the source before you decide. If something here is wrong or out of date, please
  [open an issue](https://github.com/RabinApps/kinhin/issues/new/choose) and it will be fixed.
- Where a tool's docs did not mention something, this page says "no documented ..." rather than claiming the tool cannot do it.
- kinhin's own claims use the same words as [Forge support](forges.md#what-has-been-tested). **Live-tested** means run against
  a real server. **Unit-tested only** means automated tests against fakes, never a real instance. GitHub Actions, Gitea, Forgejo and
  GitLab CE are live-tested; Buildkite, Azure Pipelines and Bitbucket Pipelines are planned.
- No prices or benchmark numbers appear here. Hosted services change pricing often, so use each vendor's own pricing page.

## At a glance

### Self-hosted Mac runner tools (the same layer as kinhin)

| Tool                              | What it is                                                                | Forges                                                                                                         | Autoscaling                                                  | Hosts                                   | License        |
| --------------------------------- | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ | --------------------------------------- | -------------- |
| **kinhin**                        | Menu bar app, CLI and daemon that autoscales ephemeral runners on one Mac | GitHub, GitLab CE, Gitea, Forgejo (Buildkite, Azure DevOps, Bitbucket united-tested only, not tested live yet) | Yes, from the queue, capped by the Mac's cores, RAM and disk | One Mac                                 | Apache-2.0     |
| **runscaler**                     | Command line autoscaler for Docker containers or Tart macOS VMs           | GitHub                                                                                                         | Yes, on GitHub's runner scale set API, scales from zero      | One host                                | MIT            |
| **Cilicon**                       | macOS app that runs ephemeral Tart-format VMs                             | GitHub Actions, Buildkite, GitLab Runner, custom scripts                                                       | No documented queue-based scaling                            | One Mac                                 | MIT            |
| **Tartelet**                      | macOS app that runs ephemeral Tart VMs as runners                         | GitHub                                                                                                         | Runs up to two runners                                       | One Mac                                 | MIT            |
| **Orchard**                       | Orchestrator for Tart VMs across a cluster of Macs                        | None (not a CI integration)                                                                                    | Schedules VMs on request                                     | Many Macs                               | See repository |
| **GitLab Runner + Tart executor** | GitLab custom executor that creates a Tart VM per job                     | GitLab                                                                                                         | Concurrency set by hand with `concurrent`                    | One or more Macs                        | See repository |
| **Anka Build** (Veertu)           | Commercial macOS VM platform with controller and registry                 | Jenkins, TeamCity, GitLab, GitHub Actions, Buildkite, Azure DevOps                                             | Controller queues and load balances                          | Many Macs, own or hosted                | Commercial     |
| **Orka** (MacStadium)             | Kubernetes-native macOS VM platform                                       | Plugins for GitHub Actions, GitLab, Buildkite, Azure DevOps, Jenkins, Drone, TeamCity                          | Elastic pools, burst capacity                                | MacStadium cloud, AWS, or your own Macs | Commercial     |

### Full CI systems and Linux-oriented tools

| Tool                                | What it is                                                      | macOS jobs                            | Autoscaling                                                                          |
| ----------------------------------- | --------------------------------------------------------------- | ------------------------------------- | ------------------------------------------------------------------------------------ |
| **Woodpecker CI**                   | A complete CI server with agents and plugins (replaces your CI) | Local backend only, with no isolation | Separate autoscaler, described as not feature-complete, documented for Hetzner Cloud |
| **Actions Runner Controller (ARC)** | Kubernetes operator for GitHub Actions runners                  | No documented macOS support           | Runner scale sets, ephemeral container runners                                       |

### Hosted macOS CI (no hardware to own)

| Service                   | What it is                                                                   |
| ------------------------- | ---------------------------------------------------------------------------- |
| **GitHub-hosted runners** | macOS images on Apple Silicon and Intel, a fresh VM for each job             |
| **GitLab hosted runners** | macOS runners on Apple Silicon, in beta and limited to some plans            |
| **Cirrus Runners**        | Hosted GitHub Actions runners on Apple Silicon, single-use VMs built on Tart |
| **Namespace**             | Hosted runners including macOS on Apple Silicon                              |
| **Depot**                 | Hosted GitHub Actions runners including macOS on some plans                  |

## Closest tools: self-hosted Mac runners

### runscaler

**What it does.** An open source autoscaler for GitHub Actions. It registers a runner scale set, waits for GitHub to hand
out jobs, and starts either a Docker container or a Tart macOS VM for each one using a just-in-time runner configuration.
It scales from zero, needs no Kubernetes, can keep a warm pool of pre-booted macOS VMs for fast pickup, and has a
`doctor --fix` command that cleans up orphans.

**What kinhin does.** kinhin also uses GitHub's scale set API with just-in-time registration for GitHub accounts, and it also
runs one ephemeral instance per job. It adds six more forges, four runtimes (Tart, apple/container, Docker, host), a menu
bar app and LaunchAgent daemon, a capacity cap computed from your Mac, per-repo and per-workflow routing, and baked or
per-project toolchains. It also has an opt-in [warm pool](scaling.md#warm-pool): set `warm_pool` and kinhin keeps Tart
VMs booted and waiting, so a job skips the clone and boot.

**What kinhin lacks.** The warm pool is off by default and covers only base-image Tart jobs; jobs routed to a per-project
image, and the other runtimes, still pay the clone and boot time. kinhin is also much newer in some of its paths: outside
GitHub Actions, nothing has been run against a real server yet.

**Pick runscaler when** you only use GitHub and want a small command line tool.

### Cilicon and Tartelet

**What they do.** Both are macOS apps that run ephemeral Tart-format VMs as CI runners. Cilicon handles GitHub Actions,
Buildkite, GitLab Runner and custom scripts. Tartelet handles GitHub and runs up to two runners at a time. Neither
documents scaling to the queue.

**What kinhin does.** It watches the queue and sizes the fleet for you, serves several forges at once, and covers Linux jobs.

**What kinhin lacks.** Their scope is smaller, which is also their appeal. If one VM at a time is enough, a smaller tool has
fewer moving parts.

### Orchard

**What it does.** Orchard is a controller and workers that manage Tart VMs across a cluster of Apple Silicon Macs, with a
CLI and a REST API. Its docs describe orchestration of VMs, not a CI integration.

**What kinhin does.** kinhin works at a different layer: it talks to your forge, decides how many runners the queue needs,
and places them on one Mac.

**What kinhin lacks.** **Multi-Mac clustering.** kinhin manages the Mac it runs on and does not schedule across machines. If
you have a rack of Macs, an orchestrator like Orchard, Anka or Orka is the better foundation.

### GitLab Runner with the Tart executor

**What it does.** A GitLab custom executor creates an isolated, ephemeral Tart VM for each job. Concurrency is a number you
set in `config.toml`.

**What kinhin does.** Scaling follows the queue instead of a fixed number, and the same fleet can serve other forges. kinhin's
GitLab support is live-tested on GitLab CE.

**What kinhin lacks.** Maturity on GitLab: the executor has a longer track record.

### Anka Build and Orka

**What they do.** Both are commercial platforms for fleets of Mac VMs with central management. Anka Build has a controller,
a template registry and nodes that run on your own Macs, managed hosting or AWS EC2 Mac, with SSO, high availability and
USB device attach. Orka is Kubernetes-native, runs on MacStadium's cloud, on AWS or on your own Macs, and offers burst
capacity.

**What kinhin lacks.** Everything that comes with a commercial fleet product: many-node scale, high availability, vendor
support and hybrid cloud. kinhin is free, single-host and built by one developer.

**What kinhin offers instead.** A small, free tool you can install in a minute for a single Mac, with no controller to run.

## Full CI systems and Linux-oriented tools

### Woodpecker CI

**What it does.** Woodpecker is a complete, Apache-2.0 CI/CD system: a server, agents, a web UI, a plugin ecosystem and its
own pipeline syntax. It is light (the project cites roughly 100 MB for the server and 30 MB for an agent at idle) and can
run on a Raspberry Pi. It works with GitHub, Gitea, Forgejo, GitLab, Bitbucket and Bitbucket Datacenter. Its docs describe
connecting multiple forges to one server as experimental.

The important difference is the category. **Woodpecker replaces your CI. kinhin does not.** kinhin keeps your GitHub Actions or
GitLab workflows unchanged and supplies the machines they run on. Woodpecker asks you to run a CI server and write
Woodpecker pipelines.

**macOS.** Per Woodpecker's supported platforms page, the server has no macOS build and the Docker and Kubernetes backends
do not run on macOS. The agent does run on macOS, but only with the **local backend, which runs pipeline commands directly
on the agent host with no isolation**. Its docs warn that a pipeline can read the agent's configuration, including the agent
secret, and recommend it only for trusted private setups. So on a Mac the choices are: run the agent directly on the Mac,
or put it inside a VM you manage yourself. We found no documented Tart support in Woodpecker. Running an agent inside a Tart
VM looks plausible but is something you would build and operate yourself.

**Concurrency.** Each agent runs one workflow at a time by default (`WOODPECKER_MAX_WORKFLOWS` defaults to 1). Woodpecker has
a separate autoscaler project, which its docs call not feature-complete, and its example is Hetzner Cloud. We found no
documented autoscaling for Apple hardware.

**What kinhin does.** Ephemeral Tart VMs (and Linux containers or microVMs) per job with the capacity cap, plus
queue-driven scaling for the CI you already have. GitHub Actions (Tart macOS VMs, apple/container) and Gitea Actions (Docker) are live-tested;
the other forges are not yet.

**What kinhin lacks.** Everything a CI system itself provides: no server, UI, pipeline language or plugins of its own.
Woodpecker also has Windows agents and Windows container support, and runs on Linux, FreeBSD and Windows servers. kinhin
runs on an Apple Silicon Mac only and has no Windows runners.

**Pick Woodpecker when** you want a small, self-hosted CI server that you fully control, mostly for Linux or container
workloads. **Pick kinhin when** you already use GitHub Actions or another supported forge and want parallel, clean Mac jobs
on your own hardware.

### Actions Runner Controller (ARC)

**What it does.** ARC is GitHub's Kubernetes operator for self-hosted runners. It scales runner scale sets (per repository,
organization or enterprise) up and down with the number of workflows, and runners can be ephemeral and container-based.

**What kinhin does.** It fills the gap on a Mac: macOS VMs and Apple's container runtime, with no Kubernetes needed. We found
no documented macOS support in ARC's own README.

**What kinhin lacks.** Kubernetes-scale elasticity, multiple nodes, and the cloud operations tooling that comes with it. If
your jobs are Linux and you already run a cluster, ARC is the natural choice.

## Hosted macOS CI

**What they do.** GitHub-hosted runners give you macOS images on Apple Silicon and Intel with a fresh VM per job and no
hardware to own. GitLab offers hosted macOS runners in beta on some plans. Cirrus Runners, Namespace and Depot offer hosted
GitHub Actions runners that include macOS on Apple Silicon. Cirrus Runners are built on Tart and billed per concurrent
runner rather than per minute. RunsOn, which runs in your own AWS account, documents Linux and Windows but says macOS
stays on GitHub-hosted runners. Dedicated iOS services such as Bitrise, Codemagic and Xcode Cloud also exist but are not
compared here.

**What kinhin lacks.** Burst capacity beyond one Mac, an SLA, support, and zero maintenance. With hosted CI there is no Mac to
look after and no image to bake.

**What kinhin offers instead.** Your own hardware at a fixed cost, so you can run as many jobs as the Mac can hold without a
per-minute meter, plus control over images, toolchains and network. This is the problem kinhin was built to solve after the
free monthly minutes ran out.

## A note on Tart

kinhin's macOS VMs are Tart VMs, and most of the self-hosted tools above use Tart too. Tart is now published under the
`openai` organization on GitHub. Its repository carries the **Functional Source License (FSL-1.1-ALv2)**, which allows any
purpose other than a "Competing Use" (commercially offering a product that substitutes for Tart), and says internal use is a
permitted purpose. Read the [license](https://github.com/openai/tart/blob/main/LICENSE) yourself, and ask a lawyer if your
use is unusual. Apple's own terms also limit a Mac to two macOS VMs at once, which applies to every Tart-based tool here
(see [Why kinhin](why.md#why-the-usual-workarounds-fall-short)).

## What kinhin is missing

An honest summary, with the roadmap for what is planned:

- **No multi-Mac clustering or cloud burst.** One Mac is one fleet.
- **Apple Silicon Mac hosts only.** No Intel Macs, Linux or Windows hosts.
- **No Windows runners.** A possibility after v0.1.0, not a promise.
- **No CI server, UI or pipeline language of its own.** kinhin relies on your forge for those.
- **The warm pool is limited to base-image Tart jobs.** Warm VMs also take slots under the two-macOS-VM ceiling. See
  [Warm pool](scaling.md#warm-pool).
- **Most of it has never run against a real server.** Only GitHub Actions (Tart macOS VMs, apple/container) and Gitea
  Actions (Docker) are live-tested. See [what has been tested](forges.md#what-has-been-tested) and the [beta roadmap](beta-roadmap.md).
- **The in-app updater is not exercised yet**, and there is no soak-test result.
- **No commercial support or SLA.** One maintainer.

## What kinhin has

- **An opt-in warm pool** of pre-booted Tart macOS VMs, so a job skips clone and boot ([Warm pool](scaling.md#warm-pool)).
- **One engine for four forges and four runtimes**, with routing per repo, workflow or `runs-on:` label
  ([Runtimes](runtimes.md)).
- **Fresh, isolated, ephemeral instances** by default, with the runner deregistered and the instance deleted after each job.
- **A capacity cap computed from your Mac,** with host headroom reserved ([How scaling works](scaling.md)).
- **A menu bar app, CLI and daemon** that share one config and one fleet.
- **Toolchain baking, pinning and a shared cache** ([Toolchains](toolchains.md)).
- **No telemetry,** and tokens in the Keychain.

## Which should I choose?

- **One Mac, you keep GitHub Actions or GitLab, and you want parallel clean jobs:** kinhin.
- **A small, self-hosted CI server you control, mostly Linux:** Woodpecker CI.
- **Linux jobs on a Kubernetes cluster you already run:** Actions Runner Controller.
- **Many Macs in a rack or cloud:** Orchard, Anka Build or Orka.
- **No hardware at all, and per-job cost is acceptable:** a hosted macOS service.

Not sure? The [Quick start](../website/guide/quick-start.md) takes a few minutes, and a report of what worked or did not is
the most useful thing you can send.

## Sources

Checked on 2026-10-08.

- Woodpecker CI: [intro](https://woodpecker-ci.org/docs/intro),
  [supported platforms](https://woodpecker-ci.org/docs/administration/installation/supported-platforms),
  [local backend](https://woodpecker-ci.org/docs/administration/configuration/backends/local),
  [agent configuration](https://woodpecker-ci.org/docs/administration/configuration/agent),
  [autoscaler](https://woodpecker-ci.org/docs/administration/configuration/autoscaler),
  [forges](https://woodpecker-ci.org/docs/administration/configuration/forges/overview),
  [repository](https://github.com/woodpecker-ci/woodpecker)
- [Actions Runner Controller](https://github.com/actions/actions-runner-controller)
- [runscaler](https://github.com/ysya/runscaler), [Cilicon](https://github.com/traderepublic/Cilicon),
  [Tartelet](https://github.com/shapehq/tartelet)
- [Orchard](https://github.com/openai/orchard), [Tart](https://github.com/openai/tart) and its
  [license](https://github.com/openai/tart/blob/main/LICENSE), [Tart with GitLab Runner](https://tart.run/integrations/gitlab-runner/)
- [Anka Build](https://veertu.com/), [Orka](https://www.macstadium.com/orka)
- [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
  [Cirrus Runners](https://cirrus-runners.app/), [Namespace](https://namespace.so/docs/solutions/github-actions),
  [Depot](https://depot.dev/docs/github-actions/overview), [RunsOn](https://runs-on.com/)
