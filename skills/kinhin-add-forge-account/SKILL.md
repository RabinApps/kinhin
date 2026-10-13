---
name: kinhin-add-forge-account
description: Connect an existing kinhin install to a CI forge account - GitHub, Gitea, Forgejo or GitLab CE. Use when the user wants kinhin to serve jobs from another repo, org, project or forge.
---

# Add a forge account

One fleet can serve several forges at once. Run `kinhin help` for the current flags.

**Beta status:** GitHub, Gitea, Forgejo and GitLab CE are supported. Buildkite, Azure DevOps and Bitbucket are planned
and not supported yet: tell the user so instead of setting one up.

## Steps

1. Pick a name (lowercase letters, digits, `-`, `_`) and the scope (see the `kinhin-configure` skill for the scope shape
   per forge).
2. Add the account:

```bash
kinhin auth add NAME --<github|gitlab|gitea|forgejo> --scope SCOPE [--instance URL]
```

   `--instance` is required for Gitea, Forgejo and GitLab CE, and optional for GitHub (GHES or GHEC hosts). The command
   prints the token permissions that forge needs.
3. Store the token: `kinhin auth set --account NAME`. Do not paste tokens into chat, and avoid `--token X` (pipe it with `--token-stdin` if a script must).
4. `kinhin config validate`, then `kinhin auth status --account NAME`. A good check means the token reaches the forge and
   the scope is valid.
5. Add the job targeting in the repo's workflow or pipeline (`runs-on` labels, or GitLab tags; see the
   `kinhin-configure` skill). The job must request every label on the account.
6. If the image was built before this account existed, re-run `kinhin image prepare`. Runner agents are baked in only for
   forges that have a token.
7. Verify with `kinhin doctor`, then trigger a job and watch `kinhin watch`.

## Caveats

- Self-hosted forges need `https://` unless loopback or `allow_insecure_http: true`.
- A repo `.kinhin/config.yml` (or `.kinhin.yml`) is honored only on GitHub, Gitea/Forgejo and GitLab.
- Host mode needs `consent: true` on the route.
- Remove an account with `kinhin auth remove NAME`. `kinhin auth list` shows what is connected.

## More

- [Forge guide](https://github.com/RabinApps/kinhin/blob/main/docs/forges.md)
- [Forge API notes](https://github.com/RabinApps/kinhin/blob/main/docs/forges/README.md)
