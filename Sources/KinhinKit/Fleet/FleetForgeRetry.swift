import Foundation

/// Backoff bookkeeping for accounts that failed to attach (a bad token, a
/// transient network error, an unreachable server).
struct ForgeRetryState: Sendable {
    static let initialDelay: TimeInterval = 30
    static let maxDelay: TimeInterval = 300

    var delay: TimeInterval = ForgeRetryState.initialDelay
    var nextAttempt: Date = .distantPast
    /// The background attempt currently running (single-flight), if any.
    var inFlight: Task<Void, Never>?

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
    /// Starts `retryDetachedForgesIfDue` as a background task when a detached account is due, at
    /// most one at a time. Attaching verifies the token against the forge (and may set up scale
    /// sets), which can take far longer than a reconcile pass should wait; the pass only kicks it.
    func startForgeRetryIfDue(now: Date = Date()) {
        guard running else { return }
        forgeState.withLock { state in
            guard state.retry.inFlight == nil, now >= state.retry.nextAttempt,
                config.accounts.contains(where: { state.byPlatform[$0.name] == nil })
            else { return }
            // The task clears its own slot under the same lock this assignment is made in, so it
            // can never clear before it was stored.
            state.retry.inFlight = Task { [weak self] in
                await self?.retryDetachedForgesIfDue(now: now)
                self?.forgeState.withLock { $0.retry.inFlight = nil }
            }
        }
    }

    /// Retries every detached account now, ignoring the backoff, through the
    /// same single-flight slot as `startForgeRetryIfDue`: it joins an attempt
    /// already running instead of starting a second, overlapping one.
    func retryDetachedForgesNow() async {
        let attempt = forgeState.withLock { state -> Task<Void, Never>? in
            if let running = state.retry.inFlight { return running }
            guard config.accounts.contains(where: { state.byPlatform[$0.name] == nil }) else { return nil }
            // The task clears its own slot under the same lock it is stored in.
            let task = Task { [weak self] in
                await self?.retryDetachedForgesIfDue(ignoreBackoff: true)
                self?.forgeState.withLock { $0.retry.inFlight = nil }
            }
            state.retry.inFlight = task
            return task
        }
        await attempt?.value
    }

    /// Re-attaches accounts that are currently detached: any account whose
    /// verification failed, whose token was missing, or whose server was
    /// unreachable. Runs from every reconcile pass but only acts when the
    /// backoff has elapsed (30s, doubling to 5 min), and stops on its own
    /// once every configured account is attached. `ignoreBackoff` is for
    /// tests.
    func retryDetachedForgesIfDue(now: Date = Date(), ignoreBackoff: Bool = false) async {
        guard running else { return }
        let due = forgeState.withLock { now >= $0.retry.nextAttempt }
        let accountsDetached = !detachedAccounts().isEmpty
        guard accountsDetached, ignoreBackoff || due else { return }

        await attachAccountsIfNeeded()

        let stillDetached = !detachedAccounts().isEmpty
        forgeState.withLock { state in
            if stillDetached {
                state.retry.backOff(now: now)
            } else {
                state.retry.scheduleNext(after: ForgeRetryState.initialDelay, now: now)
            }
        }
    }
}
