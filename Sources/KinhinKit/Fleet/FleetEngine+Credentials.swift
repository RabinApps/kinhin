import Foundation

// FleetEngine — token swaps and the Gitea/Forgejo forges, which attach once
// their token and server are reachable (at start, or later via the retry
// loop in FleetForgeRetry.swift).
extension FleetEngine {
    /// Swap in a new PAT: rebuilds the GitHub client and drops the cached
    /// registration token (minted under the old token's authority). Safe to
    /// call while running — the next reconcile/registration uses the new
    /// credentials; in-flight VMs are untouched.
    public func replaceCredentials(pat: String) async {
        guard config.githubEnabled else {
            Log.warn("engine", "GitHub token replaced but GitHub is not configured — ignoring")
            return
        }
        let fresh = GitHubCredentials(token: pat, scope: config.repo)
        let client = githubFactory.make(fresh)
        githubAuth.withLock { auth in
            auth.credentials = fresh
            auth.client = client
        }
        forgeState.withLock { state in
            state.byPlatform["github"] = GitHubForge(
                credentials: .github(token: fresh.token, scope: fresh.scope), labels: config.labels, client: client)
            state.retry.githubDetached = false
        }
        registrationTokens.invalidate()
        Log.info("engine", "GitHub credentials replaced (scope: \(config.repo))")
    }

    /// Reads a token from the Keychain. When there is none, the reason goes to
    /// the log and `lastError`: `missing` for a token that was never stored, the
    /// Keychain's own error when it could not be read (a locked keychain must
    /// not read as "run kinhin auth set").
    func storedToken(missing: String, load: () throws -> String?) async -> String? {
        let message: String
        do {
            if let token = try load() { return token }
            message = missing
        } catch {
            message = error.localizedDescription
        }
        Log.error("engine", message)
        await statusBox.modify { $0.lastError = message }
        return nil
    }

    /// Build the Gitea forge when the config declares one. The registration
    /// token mint doubles as the permission probe — a failure here keeps the
    /// fleet running GitHub-only with the reason in lastError (never a
    /// silently dead forge).
    func attachGiteaForgeIfNeeded() async {
        guard let giteaConfig = config.gitea else { return }
        guard forgeState.withLock({ $0.byPlatform["gitea"] == nil }) else { return }
        guard
            let token = await storedToken(
                missing: "gitea configured but no access token stored — run: kinhin auth set --gitea",
                load: { try KeychainTokenStore.load(forge: .gitea) })
        else { return }
        do {
            let credentials = GiteaCredentials(token: token, scope: giteaConfig.scope, instance: giteaConfig.instance)
            let forge = try await GiteaForge.make(
                credentials: credentials,
                labels: giteaConfig.labels ?? ["macos:host"],
                demandFloor: config.minRunners
            )
            forgeState.withLock { $0.byPlatform["gitea"] = forge }
            Log.info("engine", "gitea forge attached (\(giteaConfig.scope) @ \(giteaConfig.instance))")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error("engine", "gitea forge unavailable: \(message)")
            await statusBox.modify { $0.lastError = "gitea: \(message)" }
        }
    }

    /// Swap the Gitea access token live: rebuilds the forge (re-minting its
    /// registration token) or attaches one for the first time.
    public func replaceGiteaToken(_ token: String) async {
        guard let giteaConfig = config.gitea else {
            Log.warn("engine", "gitea token replaced but no gitea forge is configured")
            return
        }
        do {
            let credentials = GiteaCredentials(token: token, scope: giteaConfig.scope, instance: giteaConfig.instance)
            let forge = try await GiteaForge.make(
                credentials: credentials,
                labels: giteaConfig.labels ?? ["macos:host"],
                demandFloor: config.minRunners
            )
            forgeState.withLock { $0.byPlatform["gitea"] = forge }
            Log.info("engine", "gitea credentials replaced (\(giteaConfig.scope) @ \(giteaConfig.instance))")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error("engine", "gitea token replacement failed: \(message)")
            await statusBox.modify { $0.lastError = "gitea: \(message)" }
        }
    }

    /// Build the Forgejo forge when the config declares one. Wire-compatible
    /// with Gitea (same client and runner binary); a failure here keeps the
    /// fleet running with the reason in lastError.
    func attachForgejoForgeIfNeeded() async {
        guard let forgejoConfig = config.forgejo else { return }
        guard forgeState.withLock({ $0.byPlatform["forgejo"] == nil }) else { return }
        guard
            let token = await storedToken(
                missing: "forgejo configured but no access token stored — run: kinhin auth set --forgejo",
                load: { try KeychainTokenStore.load(forge: .forgejo) })
        else { return }
        do {
            let credentials = GiteaCredentials(
                token: token, scope: forgejoConfig.scope, instance: forgejoConfig.instance)
            let forge = try await ForgejoForge.make(
                credentials: credentials,
                labels: forgejoConfig.labels ?? ["macos:host"],
                demandFloor: config.minRunners
            )
            forgeState.withLock { $0.byPlatform["forgejo"] = forge }
            Log.info("engine", "forgejo forge attached (\(forgejoConfig.scope) @ \(forgejoConfig.instance))")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error("engine", "forgejo forge unavailable: \(message)")
            await statusBox.modify { $0.lastError = "forgejo: \(message)" }
        }
    }

    /// Swap the Forgejo access token live: rebuilds the forge (re-minting its
    /// registration token) or attaches one for the first time.
    public func replaceForgejoToken(_ token: String) async {
        guard let forgejoConfig = config.forgejo else {
            Log.warn("engine", "forgejo token replaced but no forgejo forge is configured")
            return
        }
        do {
            let credentials = GiteaCredentials(
                token: token, scope: forgejoConfig.scope, instance: forgejoConfig.instance)
            let forge = try await ForgejoForge.make(
                credentials: credentials,
                labels: forgejoConfig.labels ?? ["macos:host"],
                demandFloor: config.minRunners
            )
            forgeState.withLock { $0.byPlatform["forgejo"] = forge }
            Log.info("engine", "forgejo credentials replaced (\(forgejoConfig.scope) @ \(forgejoConfig.instance))")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error("engine", "forgejo token replacement failed: \(message)")
            await statusBox.modify { $0.lastError = "forgejo: \(message)" }
        }
    }
}
