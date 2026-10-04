# Plan: OAuth 2.0 login for GitHub + Gitea/Forgejo, alongside token auth

## Goal

Add a browser/device-code OAuth login path for GitHub and Gitea/Forgejo that ends in a stored credential the existing fleet can use, without removing or weakening today's token-auth path. The flow should live behind the existing auth seams so the app and CLI can both use it, and the stored result should enter the system through the same Keychain/token path the fleet already consumes.

This is a first cut, not a blanket "OAuth for every forge" feature. Bitbucket is explicitly out for now because this codebase already uses OAuth in a different sense there — per-runner OAuth client id/secret minted at runner creation — and lumping user login into that would be confusing. GitLab, Buildkite, and Azure DevOps are deferred until the core flow and credential shape are settled.

## Non-goal for this turn

- Replacing token auth.
- Refresh-token/long-lived session management.
- A generic OAuth library or a new "OAuth credential" type that all forges must adopt.
- Adding OAuth to every current provider in one go.

## What "OAuth login" means here

For this plan, "OAuth login" means:

1. The user starts a login for a forge account.
2. The app or CLI obtains consent through the provider's OAuth 2.0 flow — browser-based for the app, device-code or equivalent for the CLI where the provider supports it, or whichever path is the natural one for that provider.
3. The provider returns an access token (and, where relevant, whatever else the provider hands back).
4. Kinhin stores that result in the Keychain as the account's credential.
5. The existing fleet, health checks, and auth-status reporting continue to work against that stored credential.

This keeps the feature aligned with your chosen answers:

- browser/device login, store the result
- an alternative alongside token auth
- GitHub + Gitea/Forgejo first
- store the OAuth access token as the forge credential
- same flow behind `AuthEnvironment`, UI secondary

## First-cut scope

### In scope

- A new auth flow for GitHub and Gitea/Forgejo that produces a stored credential.
- The credential is treated by the rest of the system as the account's stored token/credential for that account, using the existing Keychain paths.
- Token auth stays working unchanged.
- The flow is reachable from both the app and the CLI via the same underlying plumbing.
- `kinhin auth status`, doctor, and the app's token/connection state keep reporting sensibly for OAuth-stored accounts.

### Out of scope

- Bitbucket user OAuth login.
- GitLab, Buildkite, Azure DevOps.
- Any new refresh-token lifecycle, token renewal, or "stay signed in" state machine.
- Per-forge OAuth provider libraries added speculatively.
- Any change that repurposes Bitbucket's existing per-runner OAuth credentials into user login.

## Design constraints already in the code

The existing code is already structured the way you want this to be:

- `AuthEnvironment` is injectable and already has separate check hooks per forge.
- `KeychainTokenStore` is the stored-credential seam, including named-account support.
- Forges are built through `Forge.make(credentials:...)` and verified in `attach(account:token:verify:)`.
- `TokenRequirements` and `TokenHealthCheck` already express what each forge's credential must be able to do.
- `ForgeTransport` already knows the per-forge authorization header shape.

So the OAuth work is mostly about **how a credential gets produced and validated before it is stored**, not about changing the fleet.

That said, the codebase is currently organized around bearer-style access tokens. The relevant question is not "can we add OAuth" but "what do we store after the OAuth flow, and does it satisfy the same expectations the rest of the system already has?"

## Core design decision: credential shape

This is the most important decision in the plan, because it determines whether the feature is clean or awkward.

### Recommended shape for this first cut

For both GitHub and Gitea/Forgejo, the OAuth flow should produce **a stored credential that behaves like today's stored token for that account**.

Concretely:

- If the OAuth flow returns an access token that the fleet can use directly, store that access token as the account credential.
- If a provider's OAuth access token is not the right thing for the fleet to hold long-term, do not force it. Instead, treat the OAuth result as the login step and store the credential the fleet actually needs, if the provider supports obtaining it from the OAuth result.

This is why the plan prefers "whatever fits the fleet best" for GitHub rather than insisting on a plain user OAuth access token.

### Why this matters

The fleet's expectations are already encoded:

- GitHub needs to mint runner registration tokens, list runners, read queued/running workflow runs, and cancel/skip runs.
- Gitea/Forgejo needs runner registration, runner lifecycle, queued-job visibility, and repository scoping.

If the stored OAuth result cannot do those things, the feature will look complete in the auth UI but fail in the fleet. That would be worse than not having OAuth yet.

So the plan treats the credential shape as a per-provider decision, not a uniform one.

## Provider-by-provider plan

### GitHub

GitHub is the harder and more important case, because "GitHub OAuth login" is not obviously the same thing as "a token that can do what kinhin needs."

Two reasonable shapes exist:

1. **Plain OAuth user access token.**
   - Simpler to describe as "OAuth login."
   - Must still be checked against the actual API capabilities kinhin needs, because a generic GitHub OAuth token is not automatically the same as the PAT-style credential the existing code assumes.
   - This is the natural starting point if you want the most literal "OAuth login" story.

2. **GitHub App / installation-oriented path.**
   - May be a better fit for what the fleet actually does.
   - This is the reason the plan does not force "plain OAuth user token" for GitHub: if the fleet's needs are better served by an app/installation-shaped credential, that is a legitimate OAuth-adjacent login outcome and should be considered part of the same feature.

For the first cut, the plan does not commit to one GitHub shape in advance. It commits to this:

- The GitHub flow must produce a stored credential.
- That credential must be verified against real GitHub API capabilities kinhin uses, not just against "we got an OAuth token."
- If a plain user OAuth token satisfies those needs cleanly, use it.
- If it does not, the GitHub path should be designed around the credential shape that does, and the auth UX should describe what was stored rather than pretending it is a generic OAuth token.

This is the most honest way to honor your answer without building something that only looks complete.

### Gitea / Forgejo

This is the cleaner case.

- Gitea/Forgejo are OAuth 2.0 providers.
- The existing token path already assumes a bearer-style access token with the right scopes.
- The natural first-cut story is: OAuth login returns an access token, that access token is stored as the account credential, and the existing Gitea/Forgejo forge path consumes it.

So for Gitea/Forgejo, the plan is more conventional:

- OAuth login flow.
- Store the resulting access token as the account credential.
- Verify it can do the expected Gitea/Forgejo operations.
- Keep the existing token and health-check paths working.

This is where the "store the OAuth access token as the forge credential" answer fits most cleanly.

## What changes where

### Auth plumbing

Add a new credential-production path behind `AuthEnvironment` and the app/CLI auth flows:

- a flow starter for "log in this account with OAuth"
- a way to complete the flow and hand back a credential
- the same Keychain save path the existing auth commands already use
- the same daemon-notification path when a credential is stored for a running instance

The important point is that OAuth should not become a second credential universe. It should feed the same stored-credential seam that token auth already uses.

### Provider clients / forge layer

Add the minimum needed to:

- start the OAuth flow for the provider
- exchange/or receive the result
- verify the result against the provider before storing it

This is where GitHub and Gitea/Forgejo will diverge:

- Gitea/Forgejo: likely a more standard OAuth-style exchange.
- GitHub: likely needs its own reasoning about what credential it stores, because the "obvious" OAuth token may not line up with the fleet's needs.

### Validation and health check

`kinhin auth status` and the health-check layer should treat an OAuth-stored credential the same way they treat a stored token today: it is usable if it can do the work, not because it came from OAuth.

So the plan includes:

- making sure OAuth-stored credentials participate in the same status/verification flow
- not adding a separate "OAuth status" concept unless there is a real need for one

### App and CLI UX

Because you wanted the same flow behind `AuthEnvironment` with UI secondary:

- the app can surface "Log in with GitHub / Gitea / Forgejo" as an alternative to pasting a token
- the CLI can expose the equivalent flow where it makes sense
- both should end in the same stored credential shape

Do not build two separate OAuth implementations. Build one credential-production path and let both surfaces use it.

## What does not get unified

Do not try to make Bitbucket's existing per-runner OAuth credentials look like user login. They are not the same concept. If anything, the plan should make sure the naming and architecture keep those two ideas separate so the codebase does not acquire a misleading "OAuth" label in two incompatible senses.

## Sequence

### 1. Decide the credential shape per provider

Before writing flow code, decide:

- For Gitea/Forgejo: store the OAuth access token as the account credential.
- For GitHub: decide whether the stored credential is an OAuth user access token or a different GitHub credential shape that better fits the fleet, and document that decision in the code and docs.

This decision should come first because it drives the client, verification, and UI text.

### 2. Add the OAuth credential-production seam

Add the underlying ability to start and complete an OAuth login for the supported providers, and store the result through the existing Keychain path. Keep this independent of which UI surface triggers it.

### 3. Wire the app and CLI to the new flow

Add the UX/pathway for starting OAuth login from both surfaces, using the same underlying flow. The app is likely the more natural home for a browser-based flow; the CLI may be better for a device-code flow where the provider supports it.

### 4. Make status, health, and docs honest about OAuth credentials

Ensure:

- `kinhin auth status` and the app's connection state describe OAuth-stored accounts accurately
- the token-requirements and health-check text still make sense when the credential came from OAuth
- docs explain that OAuth is an alternative way to obtain the stored credential, not a new credential model

### 5. Add the first-cut tests

Cover:

- the OAuth flow producing a stored credential through the existing Keychain seam
- the stored credential being usable by the existing forge attach/verification path
- the status/reporting layer not breaking for OAuth-stored accounts
- no regression for existing token-auth paths

## Verification

From the repository root:

```bash
swift build
swift test
swift format lint --strict -r Sources Tests
bash scripts/docs-lint.sh
```

Forge-specific notes:

- GitHub and Gitea/Forgejo are the first-cut targets.
- Bitbucket must not acquire a second, user-login OAuth meaning on top of its existing per-runner OAuth credentials.
- If the GitHub path ends up using a non-plain-OAuth credential shape, the docs and CLI/app text should say so plainly.

## Risks and open points

- The biggest risk is not OAuth itself, but storing a credential that looks right and does not actually cover the fleet's needs. That is why verification and credential-shape decisions come before UX.
- GitHub may not map cleanly onto a generic OAuth user token for everything kinhin does; the plan deliberately leaves room for a better-fitting GitHub credential shape rather than forcing a literal user OAuth token.
- If you later want refresh/renewal/long-lived sessions, that is a separate feature with a separate security and state story. This plan does not build it.

## What I would recommend as the next cut after this

If this first cut ships cleanly, the next interesting work is probably not "add OAuth to every remaining forge." It is more likely to be one of:

- deciding whether GitHub should move toward an app/installation-shaped credential rather than a generic user token
- adding refresh/renewal semantics if the provider OAuth results are short-lived and you want the app to stay logged in
- evaluating GitLab/Buildkite/Azure DevOps only after the credential shape and verification story are stable
