import Foundation

// FleetEngine — the `accounts:` forges. Every forge is an account, attached
// here keyed by its name in `ForgeState.byPlatform`, so `VMRecord.platform`
// and the demand maps carry the account name for all of them. The primary
// GitHub account additionally attaches at construction (under its account
// name) so a not-yet-verified fleet still polls demand.
extension FleetEngine {
    /// Accounts without an attached forge (never attached yet, or dropped
    /// after a failed verification) — the retry loop's work list.
    func detachedAccounts() -> [AccountConfig] {
        forgeState.withLock { state in config.accounts.filter { state.byPlatform[$0.name] == nil } }
    }

    /// The registration-token cache for an account (created on first use).
    func registrationCache(for account: String) -> RegistrationTokenCache {
        forgeState.withLock { state in
            if let cache = state.accountRegistrationTokens[account] { return cache }
            let cache = RegistrationTokenCache(ttl: TimeInterval(config.tokenTTL))
            state.accountRegistrationTokens[account] = cache
            return cache
        }
    }

    /// Drop every cached registration token (they were minted under the old
    /// tokens' authority).
    func invalidateRegistrationTokens() {
        let caches = forgeState.withLock { Array($0.accountRegistrationTokens.values) }
        for cache in caches { cache.invalidate() }
    }

    /// Attach every account that isn't attached yet. One failing account
    /// (no token, bad scope, unreachable instance) is logged and surfaced in
    /// `lastError` without affecting the others.
    func attachAccountsIfNeeded() async {
        for account in detachedAccounts() {
            guard
                let token = await storedToken(
                    missing:
                        "account '\(account.name)' has no token stored — run: kinhin auth set --account \(account.name)",
                    load: { try tokenLoader(account.forge, account.name) })
            else { continue }
            await attach(account: account, token: token, verify: true)
        }
    }

    /// Build and register the forge for one account.
    @discardableResult
    func attach(account: AccountConfig, token: String, verify: Bool) async -> Bool {
        do {
            let forge: Forge
            switch account.forge {
            case .github:
                let credentials = GitHubCredentials(token: token, scope: account.scope)
                let client = githubFactory.make(credentials)
                if verify {
                    let verification = await OrgPermissionProbe.verify(github: client, scope: account.scope)
                    guard verification.ok else {
                        throw EngineError.accountUnverified(verification.message)
                    }
                }
                forge = GitHubForge(
                    credentials: .github(token: token, scope: account.scope), labels: config.labels, client: client,
                    account: account.name)
            case .gitea, .forgejo:
                guard let instance = account.instance else {
                    throw EngineError.accountUnverified("no instance URL configured")
                }
                forge = try await GiteaForge.make(
                    forge: account.forge,
                    credentials: GiteaCredentials(token: token, scope: account.scope, instance: instance),
                    labels: account.labels ?? ["macos:host"],
                    demandFloor: config.minRunners,
                    account: account.name
                )
            case .gitlab:
                forge = try await GitLabForge.make(
                    credentials: GitLabCredentials(token: token, scope: account.scope, instance: account.instance),
                    labels: account.labels ?? config.labels,
                    account: account.name
                )
            }
            forgeState.withLock { $0.byPlatform[account.name] = forge }
            registrationCache(for: account.name).invalidate()
            Log.info("engine", "account '\(account.name)' attached (\(account.forge.rawValue): \(account.scope))")
            await statusBox.modify {
                if $0.lastError?.hasPrefix("account '\(account.name)'") == true { $0.lastError = nil }
            }
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error("engine", "account '\(account.name)' unavailable: \(message)")
            await statusBox.modify { $0.lastError = "account '\(account.name)': \(message)" }
            return false
        }
    }

    /// Swap one account's token live: re-attach its forge without
    /// re-verification (the CLI/app verified before saving). An unknown
    /// account is ignored with a warning.
    public func replaceToken(account name: String, token: String) async {
        guard let account = config.accounts.first(where: { $0.name == name }) else {
            Log.warn("engine", "token replaced for unknown account '\(name)' — ignoring")
            return
        }
        await attach(account: account, token: token, verify: false)
    }

    /// True when any attached GitHub forge is org-scoped (an org fleet
    /// reports a per-repo breakdown; single-repo scopes suppress it).
    var githubOrgScoped: Bool {
        forgeState.withLock { state in
            state.byPlatform.values.contains { forge in
                forge.credentials.forge == .github && !forge.credentials.scope.contains("/")
            }
        }
    }
}
