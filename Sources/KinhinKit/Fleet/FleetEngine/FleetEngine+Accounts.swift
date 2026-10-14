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

    /// The listeners (GitHub scale-set sessions) attached to running accounts.
    func scaleSetListeners() -> [String: [any ForgeListener]] {
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
        // A token swapped in over the daemon socket never passed through the
        // Keychain loader that registers it; mask it from here on either way.
        LogRedactor.registerSecret(token)
        if account.allowInsecureHTTP == true, account.sendsTokenOverPlainHTTP, let instance = account.instance {
            Log.warn(
                "engine",
                "account '\(account.name)' talks to \(instance) over plain http (allow_insecure_http): its access token travels in cleartext"
            )
        }
        do {
            let forge = try await account.forge.descriptor.makeForge(
                ForgeBuild(
                    account: account, token: token, verify: verify, fleetLabels: fleetLabels,
                    poolLabels: router.snapshot.servedLabels,
                    minRunners: config.minRunners, githubClient: { self.githubFactory.make($0) },
                    scaleSetTargets: { client, scaleSet in
                        await self.makeScaleSetTargets(
                            account: account, token: token, client: client, scaleSet: scaleSet)
                    }))
            let currentListeners = (forge as? any ForgeWithListeners)?.listeners ?? []
            let previousListeners = forgeState.withLock { state -> [any ForgeListener] in
                let previous = state.scaleSetListeners[account.name] ?? []
                state.byPlatform[account.name] = forge
                state.scaleSetListeners[account.name] = currentListeners.isEmpty ? nil : currentListeners
                if account.scaleSet == nil { state.scaleSetAdminTokens[account.name] = nil }
                return previous
            }
            for previous in previousListeners where !currentListeners.contains(where: { $0 === previous }) {
                await previous.stop()
            }
            registrationCache(for: account.name).invalidate()
            Log.info("engine", "account '\(account.name)' attached (\(account.forge.rawValue): \(account.scope))")
            await statusBox.modify { $0.setAlert("account:\(account.name)", nil) }
            if running {
                for listener in currentListeners { await listener.start() }
            }
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error("engine", "account '\(account.name)' unavailable: \(message)")
            await statusBox.modify { $0.setAlert("account:\(account.name)", "account '\(account.name)': \(message)") }
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

    // MARK: - GitHub scale-set targets

    /// The scale sets an account listens on. GitHub keeps only a scale set's
    /// name (plus its own system labels) on github.com, so a workflow can only
    /// reach kinhin through `runs-on: <set name>`; one set per pool, and one
    /// per named image, lets that name pick the pool and image:
    ///
    ///   `kinhin`            the Tart (macOS) pool  — the base name
    ///   `kinhin-container`  Apple containers (the pool's exclusive marker)
    ///   `kinhin-docker`     Docker slots
    ///   `kinhin-host`       the unisolated host pool
    ///   `kinhin-<image>`    a named `images:` entry (a Tart image)
    ///
    /// A fleet with a single pool and no named images keeps just the base name.
    func scaleSetPlan(account: AccountConfig, baseName: String) -> [(
        name: String, runtime: RuntimeID, labels: [String]
    )] {
        let routerState = router.snapshot
        let pools = routerState.model.pools
        var plan: [(name: String, runtime: RuntimeID, labels: [String])] = []
        let images = routerState.images.filter { !($0.labels ?? []).isEmpty }
        let single = pools.count == 1 && images.isEmpty
        for (runtime, pool) in pools.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let name: String
            if single || runtime == .tart {
                name = baseName
            } else if let marker = RuntimePool.exclusiveMarker(for: runtime) {
                // "kinhin-container" etc. — the marker already names the pool.
                name =
                    marker.hasPrefix("kinhin") ? baseName + marker.dropFirst("kinhin".count) : "\(baseName)-\(marker)"
            } else {
                name = "\(baseName)-\(runtime.rawValue)"
            }
            plan.append((name, runtime, pool.labels))
        }
        if let tart = pools[.tart] {
            for image in images {
                plan.append(("\(baseName)-\(image.name)", .tart, tart.labels + (image.labels ?? [])))
            }
        }
        // The base-named set (primary) first.
        return plan.sorted { lhs, rhs in
            if (lhs.name == baseName) != (rhs.name == baseName) { return lhs.name == baseName }
            return lhs.name < rhs.name
        }
    }

    private func makeScaleSetTargets(
        account: AccountConfig, token: String, client: GitHubServing, scaleSet: AccountConfig.ScaleSetConfig
    ) async -> [ScaleSetTarget] {
        let plan = scaleSetPlan(account: account, baseName: scaleSet.name)
        var targets: [ScaleSetTarget] = []
        for entry in plan {
            let listener = await makeGitHubScaleSetListener(
                account: account, token: token, client: client, scaleSet: scaleSet, setName: entry.name,
                runtime: entry.runtime)
            targets.append(
                ScaleSetTarget(
                    setName: entry.name, runtime: entry.runtime, routingLabels: entry.labels, listener: listener))
        }
        Log.info(
            "scaleset",
            "account '\(account.name)' listens on scale sets: " + plan.map(\.name).joined(separator: ", ")
                + " — workflows target one with `runs-on: <name>`")
        return targets
    }

    /// Build a listener whose privileged requests obtain an Actions JWT from
    /// this account's GitHub registration-token flow.
    ///
    /// The engine owns the listener (through `forgeState`), so every closure the
    /// listener keeps captures the engine weakly: a strong capture would be a
    /// cycle that keeps a replaced engine alive for as long as its listener
    /// object is. A closure that outlives the engine fails the request instead.
    private func makeGitHubScaleSetListener(
        account: AccountConfig, token: String, client: GitHubServing, scaleSet: AccountConfig.ScaleSetConfig,
        setName: String, runtime: RuntimeID
    ) async -> GitHubScaleSetListener {
        let credentials = GitHubCredentials(
            token: token, scope: account.scope, instance: account.instance,
            allowInsecureHTTP: account.allowInsecureHTTP ?? false)
        let scaleSetClient = GitHubScaleSetClient(
            credentials: credentials,
            adminJwtProvider: { [weak self] in
                guard let self else { throw GitHubError.scaleSetAdminTokenFailure(reason: "the engine was replaced") }
                return try await self.adminJwtForAttach(account: account, token: token, client: client)
            },
            actionsServiceURL: { [weak self] in
                self?.forgeState.withLock { $0.scaleSetAdminTokens[account.name]?.actionsURL }
            })
        return GitHubScaleSetListener(
            client: scaleSetClient,
            scaleSetIdSupplier: { [weak self] in
                guard let self else { throw GitHubError.scaleSetIdFailure(reason: "the engine was replaced") }
                return try await self.scaleSetIdForAttach(
                    account: account, token: token, githubClient: client, scaleSet: scaleSet, setName: setName)
            },
            ownerName: credentials.owner,
            fallbackRepository: account.scope.contains("/") ? account.scope : nil,
            pollInterval: .seconds(2),
            // Read on every poll: a reload that changes the caps reaches the open session.
            capacity: { [weak self] in self?.scaleSetJobCapacity(for: runtime) ?? 0 },
            onDemandUpdate: { [weak self] in self?.pollSoon() },
            sessionStore: ScaleSetSessionStore(
                directory: Paths.stateDirectory, account: account.name, scaleSet: setName)
        )
    }

    /// The job slots a scale set feeding `runtime`'s pool offers GitHub right
    /// now, from the latest reloaded caps.
    func scaleSetJobCapacity(for runtime: RuntimeID) -> Int {
        router.snapshot.jobCapacity(
            for: runtime, maxRunners: config.maxRunners, capacityCap: capacity.maxConcurrent,
            runnersPerVM: config.runnersPerVM)
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
            throw GitHubError.scaleSetAdminTokenFailure(reason: error.localizedDescription)
        }
    }

    /// Ensure the named scale set exists before exposing its id to the
    /// listener's session, statistics, and JIT-registration paths. Only the
    /// name is registered as its label: that is all GitHub keeps for a scale
    /// set on github.com, and all a workflow's `runs-on:` can match.
    private func scaleSetIdForAttach(
        account: AccountConfig,
        token: String,
        githubClient: GitHubServing,
        scaleSet: AccountConfig.ScaleSetConfig,
        setName: String
    ) async throws -> Int {
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
            let created = try await setupClient.ensureScaleSet(
                name: setName,
                labels: [setName],
                runnerGroup: scaleSet.runnerGroup
            )
            Log.info("scaleset", "scale set '\(created.name)' (id \(created.id)) ready — use `runs-on: \(setName)`")
            return created.id
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GitHubError.scaleSetIdFailure(reason: error.localizedDescription)
        }
    }

    // MARK: - Lifecycle hooks for listener forges

    /// Start the listeners attached with their forge (scale-set accounts).
    /// Polled forges have no listener to start.
    func startAttachedListeners() async {
        let forges = forgeState.withLock { Array($0.byPlatform.values) }
        for case let forge as any ForgeWithListeners in forges { await forge.startListeners() }
    }

    /// Stop the listeners attached with their forge.
    func stopAttachedListeners() async {
        let forges = forgeState.withLock { Array($0.byPlatform.values) }
        for case let forge as any ForgeWithListeners in forges { await forge.stopListeners() }
    }

    /// True when any attached forge attributes jobs per repository (an org,
    /// group or workspace scope reports a per-repo breakdown of running jobs;
    /// single-repo scopes suppress it), the same per-forge rule queued demand
    /// is attributed by.
    var attributesRunningByRepo: Bool {
        forgeState.withLock { state in state.byPlatform.values.contains { $0.attributesByRepo } }
    }
}
