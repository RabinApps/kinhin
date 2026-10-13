# Running kinhin for an open-source project

How to use kinhin for a public repository without letting a stranger's pull request run code on your Mac.

[← Back to README](../README.md) · [Security](security.md)

## The risk

A public repository accepts pull requests from anyone. A workflow that runs on a pull request runs the **pull request's
code**: its build scripts, its tests, its changes to the workflow file itself. If that job lands on kinhin, someone you
have never met runs code on your Mac, with internet access, as `admin` with passwordless `sudo` inside the guest.

kinhin's VM boundary is real isolation, and with `vm.ephemeral: true` (the default) every job gets a fresh VM that is
deleted afterwards. But a VM is a
boundary, not a guarantee: the job can use your bandwidth and CPU (mining, spam, attacks on others), probe whatever the
VM can reach, and try to escape. GitHub's own advice is to use self-hosted runners only with private repositories for
exactly this reason ([GitHub: managing access to self-hosted runners][gh-groups]).

The safe pattern is simple: **trusted code runs on kinhin, fork pull requests run on hosted runners.** The rest of this
page is how to set that up, then how to harden kinhin for the code that does reach it.

## 1. Keep fork pull requests off kinhin

Do all three. Each one alone has a gap.

### Keep public repositories out of kinhin's runner group (GitHub)

Organization runners belong to a runner group, and **by default only private repositories can use a runner group**
([GitHub][gh-groups]). Leave it that way unless you need otherwise: under the organization's **Settings → Actions →
Runner groups**, the group kinhin registers into (`scale_set.runner_group`, usually `Default`) should not allow public
repositories. If a public repository must use kinhin, limit the group to **Selected repositories** and list only that
one.

### Route fork pull requests to hosted runners in the workflow

Pick the runner per event, so pushes and your own branches use kinhin and pull requests from forks use a GitHub-hosted
runner:

```yaml
jobs:
  test:
    runs-on: ${{ (github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository) && 'kinhin' || 'macos-latest' }}
```

Replace `kinhin` with the label or scale-set name your fleet uses (`kinhin-container` for Linux containers, and so on)
and `macos-latest` with the hosted runner you want. `kinhin workflow route` does not edit expressions like this one;
write it by hand.

### Require approval before fork workflows run

In the repository's **Settings → Actions → General**, set **Approval for running fork pull request workflows from
contributors** to **Require approval for all external contributors** ([GitHub][gh-settings]). A maintainer then reads
the pull request and clicks **Approve and run** before anything executes ([approving runs from forks][gh-approve]).
Approve only after reading the diff, including changes to `.github/workflows/`.

### Never check out pull request code under `pull_request_target`

`pull_request_target` runs with the base repository's secrets and a write token. Combined with checking out the pull
request's head, it hands both to the pull request's author, on any runner. Use `pull_request` for anything that builds
or tests the pull request ([GitHub: secure use][gh-secure]).

### GitLab, Gitea and Forgejo

- **GitLab:** merge requests from forks run in the **fork's** project by default, on the fork's runners, so kinhin's
  project runners never see them. Keep it that way: don't run fork pipelines in the parent project unless a maintainer
  has reviewed the change ([merge request pipelines][gl-mr]). kinhin also flags every merge-request pipeline as untrusted.
- **Gitea and Forgejo:** kinhin cannot tell from their APIs whether a job comes from a fork, so it treats every job as
  untrusted (below). Don't register kinhin for a public repository that accepts outside pull requests unless your server
  requires approval for them; check your version's Actions settings.

## 2. Harden kinhin for the code that reaches it

Set these in `config.yaml` for any fleet that serves a public repository, even with fork pull requests routed away:
someone can still open a pull request from a branch of your own repository once they have write access, and
dependencies can be compromised.

```yaml
tart_softnet: true   # runner VMs reach the internet, not each other or your LAN
runners_per_vm: 1    # one job per VM: jobs never share a filesystem
vm:
  ephemeral: true    # a fresh VM per job, deleted afterwards (the default)
projects:
  - pattern: "your-org/public-repo"
    repo_file: false     # the repo cannot choose what is installed (the default)
    share_cache: false   # no writable cache shared between jobs (the default)
```

| Setting | Why |
| ------- | --- |
| `tart_softnet: true` | Without it a job can reach other runner VMs and your local network ([setup](runtimes.md#isolating-runner-vms-from-each-other)). |
| `runners_per_vm: 1` | With more than one runner per VM, concurrent jobs share the guest's disk and processes, so one job can tamper with another. |
| `vm.ephemeral: true` | A persistent VM keeps whatever one job left behind for the next. |
| Tart VMs, not Docker or host | Docker containers share one kernel and keep Docker's default capabilities; host mode has no isolation at all. Never add a `host` route for a public repository. |
| `share_cache: false` | The shared toolchain cache is writable and trusted by later jobs. |
| `repo_file: false` | `.kinhin/config.yml` (or `.kinhin.yml`) lets the repository decide which catalog tools are installed. |
| A repository-scoped account | Scope the account to `owner/name`, not the whole organization, so its token can manage only that repository's runners. Give the token only the permissions in [Forge support](forges.md). |
| A pinned base image | `kinhin image digest` pins the base so a republished tag cannot change what you bake. |
| A fresh `kinhin image prepare` | Images baked by older builds still allow SSH password login. |

Then run `kinhin doctor`: its security section flags softnet off, plain-http forges and a writable shared cache.

### What kinhin does on its own

- **Runners take one job.** With `vm.ephemeral: true` each job gets a fresh VM or container, deleted when the job ends
  (GitLab accounts require it).
- **Jobs that may come from a fork get no shared cache and no repo file from the pull request,** even if the project
  allows them. kinhin treats a job as possibly a fork's whenever the forge doesn't prove otherwise: GitHub scale-set
  jobs and Gitea and Forgejo jobs always, GitHub workflow runs when the payload lacks the head repository, and GitLab
  merge-request pipelines. Their `.kinhin/config.yml` is read from the default branch instead.
- **Tokens never enter the config,** and the log redacts them.

## 3. Watch it

- `kinhin status` and `kinhin pipeline` show which repository and job each VM is running.
- An unexpected repository in the queue means a runner group or label is wider than you meant.
- Keep `workflow` permissions minimal (`permissions: contents: read` at the top of each workflow), so even an approved
  job gets a read-only token.

## Checklist

- [ ] Runner group excludes public repositories, or lists only the ones you mean.
- [ ] Fork pull requests are routed to hosted runners in the workflow.
- [ ] Approval required for all external contributors.
- [ ] No `pull_request_target` job checks out pull request code.
- [ ] `tart_softnet: true`, `runners_per_vm: 1`, no host route, `share_cache` and `repo_file` off.
- [ ] Repository-scoped account with a narrow token; `kinhin doctor` shows no security warnings.

[gh-groups]: https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access
[gh-settings]: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository
[gh-approve]: https://docs.github.com/en/actions/how-tos/manage-workflow-runs/approve-runs-from-forks
[gh-secure]: https://docs.github.com/en/actions/reference/security/secure-use
[gl-mr]: https://docs.gitlab.com/ci/pipelines/merge_request_pipelines/
