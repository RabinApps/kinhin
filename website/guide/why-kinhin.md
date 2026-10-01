# Why kinhin

Self-hosted CI runners do one job at a time. kinhin exists to give your Mac real concurrency.

## The problem

A self-hosted runner is built to do one thing at a time. Register a single runner with your CI platform
and your Mac builds one job while every other job waits in the queue. Each platform draws the line a
little differently, but none of them gives you concurrency for free:

| Platform | How concurrency is limited | Source |
| -------- | -------------------------- | ------ |
| GitHub Actions | An ephemeral runner is assigned exactly one job; GitHub recommends autoscaling a fleet of them for clean, concurrent builds. | [Self-hosted runners](https://docs.github.com/en/actions/reference/runners/self-hosted-runners), [Ephemeral runners & autoscaling](https://github.blog/changelog/2021-09-20-github-actions-ephemeral-self-hosted-runners-new-webhooks-for-auto-scaling/) |
| GitLab CI/CD | Job concurrency is set by hand with `concurrent` and per-runner `limit` in `config.toml`. | [Advanced configuration](https://docs.gitlab.com/ee/runner/configuration/advanced-configuration.html) |
| Gitea / Forgejo Actions | `act_runner` runs `capacity: 1` task at a time unless you raise it. | [act_runner config example](https://gitea.com/gitea/act_runner/src/branch/main/internal/pkg/config/config.example.yaml) |
| Buildkite | One agent process by default (`--spawn` defaults to 1); more concurrency means more agents. | [`buildkite-agent start`](https://buildkite.com/docs/agent/cli-start) |
| Azure Pipelines | One job per agent, and your organization's parallel-job allotment caps how many run at once. | [Agents](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/agents), [Parallel jobs](https://learn.microsoft.com/en-us/azure/devops/pipelines/licensing/concurrent-jobs) |
| Bitbucket Pipelines | A workspace-wide runner concurrency limit and step queue sit on top of the runners you register. | [Runner concurrency](https://support.atlassian.com/bitbucket-cloud/docs/configure-runner-concurrency-and-inspect-step-queue) |

The details differ (a per-runner setting on one platform, an organization or plan limit on another), but
the shape is the same: to run jobs in parallel you need many runners, and someone has to create,
register, clean up, and retire them.

## Why the usual workarounds fall short

- **Several runners on one OS.** Jobs share one filesystem, one set of ports, and one toolchain cache, so
  state leaks between builds and parallel jobs collide.
- **Long-lived VMs per runner.** Isolation improves, but idle VMs hold RAM and disk all day and every
  platform needs its own bespoke setup.
- **Hand-rolled autoscalers.** Each forge has its own queue API and registration flow, so the glue is
  rewritten per platform.
- **macOS adds a hard ceiling.** Apple's license and Virtualization framework allow only two macOS guest
  VMs at once on a Mac, so "one VM per runner" tops out at two. Linux guests are not subject to that limit
  ([Eclectic Light](https://eclecticlight.co/2022/08/04/virtualisation-on-apple-silicon-macs-8-how-apple-limits-vms/),
  [Apple Developer Forums](https://developer.apple.com/forums/thread/830383)).

## What kinhin does instead

kinhin watches the queued jobs on every forge you configure and scales a fleet of ephemeral runners to
match. A queued job gets a fresh linked-clone VM (or container), runs, and the runner is deregistered and
the instance deleted. Nothing carries over between jobs, and nothing sits idle waiting for work.

- **One engine, every forge.** The same fleet serves GitHub, GitLab, Gitea/Forgejo, Buildkite, Azure
  Pipelines, and Bitbucket from one pool (see [Forge support](/guide/forges)).
- **Concurrency without the VM ceiling.** `runners_per_vm` runs several runner processes inside one Tart VM,
  and Linux jobs run in containers or microVMs, so you are not held to two simultaneous jobs.
- **Never overcommits your Mac.** The cap is computed from your cores, RAM, and free disk after reserving
  host headroom (see [How scaling works](https://github.com/RabinApps/kinhin/blob/main/docs/scaling.md)).

## Sources

- GitHub: [Self-hosted runners](https://docs.github.com/en/actions/reference/runners/self-hosted-runners); [Ephemeral runners & autoscaling webhooks](https://github.blog/changelog/2021-09-20-github-actions-ephemeral-self-hosted-runners-new-webhooks-for-auto-scaling/)
- GitLab: [Runner advanced configuration](https://docs.gitlab.com/ee/runner/configuration/advanced-configuration.html)
- Gitea: [act_runner config example](https://gitea.com/gitea/act_runner/src/branch/main/internal/pkg/config/config.example.yaml)
- Buildkite: [`buildkite-agent start`](https://buildkite.com/docs/agent/cli-start)
- Azure DevOps: [Agents](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/agents); [Parallel jobs](https://learn.microsoft.com/en-us/azure/devops/pipelines/licensing/concurrent-jobs)
- Bitbucket: [Configure runner concurrency](https://support.atlassian.com/bitbucket-cloud/docs/configure-runner-concurrency-and-inspect-step-queue)
- Apple macOS VM limit: [Eclectic Light](https://eclecticlight.co/2022/08/04/virtualisation-on-apple-silicon-macs-8-how-apple-limits-vms/); [Apple Developer Forums](https://developer.apple.com/forums/thread/830383)
