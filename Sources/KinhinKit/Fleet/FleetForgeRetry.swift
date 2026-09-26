import Foundation

/// Backoff bookkeeping for forges that were detached at startup (a bad
/// token, a transient network error, an unreachable Gitea server).
struct ForgeRetryState {
    static let initialDelay: TimeInterval = 30
    static let maxDelay: TimeInterval = 300

    /// GitHub is configured but failed verification and is not attached.
    var githubDetached = false
    var delay: TimeInterval = ForgeRetryState.initialDelay
    var nextAttempt: Date = .distantPast

    mutating func markGitHubDetached(now: Date) {
        githubDetached = true
        scheduleNext(after: ForgeRetryState.initialDelay, now: now)
    }

    mutating func scheduleNext(after delay: TimeInterval, now: Date) {
        self.delay = delay
        nextAttempt = now.addingTimeInterval(delay)
    }

    /// A failed attempt doubles the wait, up to five minutes.
    mutating func backOff(now: Date) {
        scheduleNext(after: min(delay * 2, ForgeRetryState.maxDelay), now: now)
    }
}

extension FleetEngine {
    /// Re-attaches configured forges that are currently detached: GitHub when
    /// its startup check failed, Gitea when its token or server was
    /// unavailable. Runs from every reconcile pass but only acts when the
    /// backoff has elapsed (30s, doubling to 5 min), and stops on its own once
    /// every configured forge is attached. `ignoreBackoff` is for tests.
    func retryDetachedForgesIfDue(now: Date = Date(), ignoreBackoff: Bool = false) async {
        guard stateLock.withLock({ running }) else { return }
        let (githubDetached, giteaDetached, forgejoDetached, due) = forgesLock.withLock {
            (
                forgeRetry.githubDetached,
                config.gitea != nil && forgesByPlatform["gitea"] == nil,
                config.forgejo != nil && forgesByPlatform["forgejo"] == nil,
                now >= forgeRetry.nextAttempt
            )
        }
        let accountsDetached = !detachedAccounts().isEmpty
        guard githubDetached || giteaDetached || forgejoDetached || accountsDetached, ignoreBackoff || due else {
            return
        }

        if githubDetached { await retryGitHub() }
        if giteaDetached {
            await attachGiteaForgeIfNeeded()
            if forgesLock.withLock({ forgesByPlatform["gitea"] != nil }) {
                await statusBox.modify { if $0.lastError?.hasPrefix("gitea") == true { $0.lastError = nil } }
            }
        }
        if forgejoDetached {
            await attachForgejoForgeIfNeeded()
            if forgesLock.withLock({ forgesByPlatform["forgejo"] != nil }) {
                await statusBox.modify { if $0.lastError?.hasPrefix("forgejo") == true { $0.lastError = nil } }
            }
        }

        if accountsDetached { await attachAccountsIfNeeded() }

        let accountsStillMissing = !detachedAccounts().isEmpty
        let stillMissing = forgesLock.withLock {
            forgeRetry.githubDetached || (config.gitea != nil && forgesByPlatform["gitea"] == nil)
                || (config.forgejo != nil && forgesByPlatform["forgejo"] == nil)
        }
        let anyMissing = stillMissing || accountsStillMissing
        forgesLock.withLock {
            if anyMissing {
                forgeRetry.backOff(now: now)
            } else {
                forgeRetry.scheduleNext(after: ForgeRetryState.initialDelay, now: now)
            }
        }
    }

    private func retryGitHub() async {
        let verification = await OrgPermissionProbe.verify(github: github, scope: config.repo)
        guard verification.ok else {
            Log.warn("engine", "GitHub still unavailable: \(verification.message)")
            await statusBox.modify { $0.lastError = "GitHub: \(verification.message)" }
            return
        }
        let creds = credentialsLock.withLock { credentials }
        let client = github
        forgesLock.withLock {
            forgesByPlatform["github"] = GitHubForge(
                credentials: .github(token: creds.token, scope: creds.scope),
                labels: config.labels, client: client)
            forgeRetry.githubDetached = false
        }
        registrationTokens.invalidate()
        await statusBox.modify { if $0.lastError?.hasPrefix("GitHub:") == true { $0.lastError = nil } }
        Log.info("engine", "GitHub forge re-attached after startup failure (scope: \(config.repo))")
    }
}
