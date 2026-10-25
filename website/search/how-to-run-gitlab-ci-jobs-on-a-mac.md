---
title: How to run GitLab CI jobs on a Mac
description: Run GitLab CI jobs that need macOS on your own Apple Silicon Mac. kinhin creates a runner per waiting job and deletes it after the job.
head:
  - - link
    - rel: canonical
      href: https://kinhin.dev/how-to-run-gitlab-ci-jobs-on-a-mac.html
---

# How to run GitLab CI jobs on a Mac

kinhin runs those jobs on an Apple Silicon Mac that you own. It watches your GitLab queue for tagged jobs and creates a runner
through the GitLab API for each job that is waiting. The runner takes one job, and the VM and the runner are deleted when
it ends.

## Set it up

Install kinhin, store its tokens and start the fleet as in
[How to run GitHub Actions on a self-hosted Mac](/how-to-run-github-actions-on-a-self-hosted-mac). Then add a GitLab account
to `kinhin config`:

```yaml
accounts:
  - name: gitlab
    forge: gitlab
    scope: "group/project" # or a group path; subgroups nest
    instance: "https://gitlab.example.com"
    labels: ["macos"] # runner tags
```

The token needs the `create_runner`, `manage_runner` and `read_api` scopes, or `api`. Creating runners needs Maintainer on a
project or Owner on a group. Store the token with `kinhin auth set`.

Ask for the Mac in your `.gitlab-ci.yml`:

```yaml
build:
  tags: [macos]
  script: xcodebuild -version
```

A waiting job counts as demand only when every tag it asks for is one that a pool advertises, so the tag must match the
`labels` you set.

## Good to know

- kinhin's GitLab support has been run end to end on GitLab CE 18.4. It supports self-managed GitLab CE 16.0 and later.
- Keep `vm.ephemeral` on. GitLab runners delete themselves after one job, so kinhin rejects `vm.ephemeral: false` for a
  GitLab account.
- Only tagged jobs in projects the token can read count. A project the token cannot read is an error, not an empty queue.

Full field reference: [Forge support](/guide/forges#gitlab).

<SearchNextSteps />
