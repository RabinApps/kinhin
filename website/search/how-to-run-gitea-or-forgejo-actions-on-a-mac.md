---
title: How to run Gitea or Forgejo Actions on a Mac
description: Run Gitea or Forgejo Actions jobs on your own Apple Silicon Mac with kinhin, which starts a VM for each job and deletes it afterwards.
head:
  - - link
    - rel: canonical
      href: https://kinhin.dev/how-to-run-gitea-or-forgejo-actions-on-a-mac.html
---

# How to run Gitea or Forgejo Actions on a Mac

Gitea and Forgejo use the same runner, so kinhin sets them up the same way. Add a Gitea or Forgejo account to your config,
then send jobs to the Mac with a label. Each job gets a fresh VM, and kinhin deletes it after the runner goes idle.

## Set it up

Install kinhin and start the fleet as in
[How to run GitHub Actions on a self-hosted Mac](/how-to-run-github-actions-on-a-self-hosted-mac). Then add the account:

```yaml
accounts:
  - name: gitea # or "forgejo" with forge: forgejo
    forge: gitea
    instance: "https://gitea.example.com"
    scope: "owner/name" # or an org name
    labels: ["macos:host"] # jobs opt in via runs-on: macos:host
```

The token is an access token with runner-management rights on the scope. Store it with `kinhin auth set --gitea` or
`kinhin auth set --forgejo`.

In the workflow, ask for the Mac by its label:

```yaml
jobs:
  build:
    runs-on: macos:host
```

## Minimum runners depend on the version

Gitea 1.24 and older report no queued job until a runner exists, so set `min_runners: 1` for them. Gitea 1.25 and later,
and Forgejo 11 and later, list queued jobs themselves and work with `min_runners: 0`.

kinhin has run end to end on Gitea 1.24 and 1.26 and on Forgejo 11. See the [tested-forge table](/guide/forges#what-has-been-tested).

The runner has no single-job mode, so kinhin deletes the VM shortly after its runners go idle.

<SearchNextSteps />
