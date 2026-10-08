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

    /// The scale-set listeners attached to running accounts.
    func scaleSetListeners() -> [String: GitHubScaleSetListener] {
        forgeState.withLock { state in state.scaleSetListeners }
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
        if account.allowInsecureHTTP == true, account.sendsTokenOverPlainHTTP, let instance = account.instance {
            Log.warn(
                "engine",
                "account '\(account.name)' talks to \(instance) over plain http (allow_insecure_http): its access token travels in cleartext"
            )
        }
        do {
            let forge: Forge
            switch account.forge {
            case .github:
                let credentials = GitHubCredentials(
                    token: token, scope: account.scope, instance: account.instance,
                    allowInsecureHTTP: account.allowInsecureHTTP ?? false)
                let client = githubFactory.make(credentials)
                if verify {
                    let verification = await OrgPermissionProbe.verify(github: client, scope: account.scope)
                    guard verification.ok else {
                        throw EngineError.accountUnverified(verification.message)
                    }
                }
                if let scaleSet = account.scaleSet {
                    let listener = await makeGitHubScaleSetListener(
                        account: account, token: token, client: client, scaleSet: scaleSet)
                    forge = GitHubScaleSetForge(
                        account: account, token: token, client: client,
                        labels: account.labels ?? config.labels, listener: listener)
                } else {
                    forge = GitHubForge(account: account, token: token, client: client, labels: config.labels)
                }
            case .gitea, .forgejo:
                guard let instance = account.instance else {
                    throw EngineError.accountUnverified("no instance URL configured")
                }
                forge = try await GiteaForge.make(
                    forge: account.forge,
                    credentials: GiteaCredentials(
                        token: token, scope: account.scope, instance: instance,
                        allowInsecureHTTP: account.allowInsecureHTTP ?? false),
                    labels: account.labels ?? ["macos:host"],
                    demandFloor: config.minRunners,
                    account: account.name
                )
            case .gitlab:
                forge = try await GitLabForge.make(
                    credentials: GitLabCredentials(
                        token: token, scope: account.scope, instance: account.instance,
                        allowInsecureHTTP: account.allowInsecureHTTP ?? false),
                    labels: account.labels ?? config.labels,
                    account: account.name
                )
            case .azuredevops:
                guard let instance = account.instance else {
                    throw EngineError.accountUnverified("no organization URL configured")
                }
                forge = try await AzureDevOpsForge.make(
                    credentials: AzureDevOpsCredentials(
                        token: token, scope: account.scope, instance: instance,
                        allowInsecureHTTP: account.allowInsecureHTTP ?? false),
                    labels: account.labels ?? [],
                    account: account.name
                )
            case .buildkite:
                forge = try await BuildkiteForge.make(
                    credentials: BuildkiteCredentials(token: token, scope: account.scope),
                    labels: account.labels ?? BuildkiteForge.defaultLabels,
                    account: account.name
                )
            case .bitbucket:
                forge = try await BitbucketForge.make(
                    credentials: BitbucketCredentials(token: token, scope: account.scope),
                    labels: account.labels ?? [],
                    account: account.name
                )
            }
            let previousListener = forgeState.withLock { state -> GitHubScaleSetListener? in
                let previous = state.scaleSetListeners[account.name]
                state.byPlatform[account.name] = forge
                if let scaleSetForge = forge as? GitHubScaleSetForge {
                    state.scaleSetListeners[account.name] = scaleSetForge.listener
                } else {
                    state.scaleSetListeners[account.name] = nil
                }
                if account.scaleSet == nil { state.scaleSetAdminTokens[account.name] = nil }
                return previous
            }
            let currentListener = (forge as? GitHubScaleSetForge)?.listener
            if let previousListener, previousListener !== currentListener {
                await previousListener.stop()
            }
            registrationCache(for: account.name).invalidate()
            Log.info("engine", "account '\(account.name)' attached (\(account.forge.rawValue): \(account.scope))")
            await statusBox.modify {
                if $0.lastError?.hasPrefix("account '\(account.name)'") == true { $0.lastError = nil }
            }
            if running, let currentListener {
                await currentListener.start()
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

    // MARK: - GitHub scale-set listener builder

    /// Build a listener whose privileged requests obtain an Actions JWT from
    /// this account's GitHub registration-token flow.
    private func makeGitHubScaleSetListener(
        account: AccountConfig, token: String, client: GitHubServing, scaleSet: AccountConfig.ScaleSetConfig
    ) async -> GitHubScaleSetListener {
        let credentials = GitHubCredentials(
            token: token, scope: account.scope, instance: account.instance,
            allowInsecureHTTP: account.allowInsecureHTTP ?? false)
        let poolCapacity = Autoscaler.jobCapacity(
            maxRunners: config.maxRunners,
            capacityCap: capacity.maxConcurrent,
            runnersPerVM: config.runnersPerVM
        )
        let scaleSetClient = GitHubScaleSetClient(
            credentials: credentials,
            adminJwtProvider: { [self] in
                try await self.adminJwtForAttach(account: account, token: token, client: client)
            },
            actionsServiceURL: { [self] in
                forgeState.withLock { $0.scaleSetAdminTokens[account.name]?.actionsURL }
            })
        return GitHubScaleSetListener(
            client: scaleSetClient,
            scaleSetIdSupplier: {
                try await self.scaleSetIdForAttach(
                    account: account,
                    token: token,
                    githubClient: client,
                    scaleSet: scaleSet
                )
            },
            ownerName: credentials.owner,
            fallbackRepository: account.scope.contains("/") ? account.scope : nil,
            pollInterval: .seconds(2),
            maxCapacity: poolCapacity,
            onDemandUpdate: { [weak self] in self?.pollSoon() },
            sessionStore: ScaleSetSessionStore(
                directory: Paths.stateDirectory, account: account.name, scaleSet: scaleSet.name)
        )
    }

    /// Mint and exchange a registration token, caching the Actions JWT until
    /// shortly before expiry. Each privileged request uses this supplier so
    /// token expiry is refreshed transparently.
    private func adminJwtForAttach(
        account: AccountConfig, token: String, client: GitHubServing
    ) async throws -> String {
        if let cached = forgeState.withLock({ $0.scaleSetAdminTokens[account.name] }),
            cached.sourceToken == token, cached.expiresAt.timeIntervalSinceNow > 60
        {
            return cached.token
        }
        do {
            let registration = try await client.fetchRegistrationToken()
            let exchangeClient = GitHubScaleSetClient(
                credentials: GitHubCredentials(
                    token: token, scope: account.scope, instance: account.instance,
                    allowInsecureHTTP: account.allowInsecureHTTP ?? false))
            let exchange = try await exchangeClient.exchangeRegistrationToken(
                registrationToken: registration.token)
            forgeState.withLock {
                $0.scaleSetAdminTokens[account.name] = ScaleSetAdminToken(
                    token: exchange.token, actionsURL: exchange.actionsUrl,
                    expiresAt: exchange.expiresAt, sourceToken: token)
            }
            return exchange.token
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScaleSetError.adminTokenFailure(reason: error.localizedDescription)
        }
    }

    /// Ensure the configured scale set exists before exposing its id to the
    /// listener's session, statistics, and JIT-registration paths.
    private func scaleSetIdForAttach(
        account: AccountConfig,
        token: String,
        githubClient: GitHubServing,
        scaleSet: AccountConfig.ScaleSetConfig
    ) async throws -> Int {
        let labels = account.labels ?? config.labels
        do {
            let setupClient = GitHubScaleSetClient(
                credentials: GitHubCredentials(
                    token: token, scope: account.scope, instance: account.instance,
                    allowInsecureHTTP: account.allowInsecureHTTP ?? false),
                adminJwtProvider: { [self] in
                    try await self.adminJwtForAttach(account: account, token: token, client: githubClient)
                },
                actionsServiceURL: { [self] in
                    forgeState.withLock { $0.scaleSetAdminTokens[account.name]?.actionsURL }
                })
            let fullLabels = Array(Set(labels + [scaleSet.name])).sorted()
            let scaleSet = try await setupClient.ensureScaleSet(
                name: scaleSet.name,
                labels: fullLabels,
                runnerGroup: scaleSet.runnerGroup
            )
            return scaleSet.id
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScaleSetError.scaleSetIdFailure(reason: error.localizedDescription)
        }
    }

    // MARK: - Lifecycle hooks for scale-set forges

    /// Start any scale-set listeners that were attached with their forge.
    /// Classic forges have no listener to start.
    func startAttachedListeners() async {
        let forges = forgeState.withLock { Array($0.byPlatform.values) }
        for forge in forges {
            if let scaleSetForge = forge as? GitHubScaleSetForge {
                await scaleSetForge.listener.start()
            }
        }
    }

    /// Stop any scale-set listeners that were attached with their forge.
    func stopAttachedListeners() async {
        let forges = forgeState.withLock { Array($0.byPlatform.values) }
        for forge in forges {
            if let scaleSetForge = forge as? GitHubScaleSetForge {
                await scaleSetForge.listener.stop()
            }
        }
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
