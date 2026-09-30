import Foundation

/// Backoff bookkeeping for accounts that failed to attach (a bad token, a
/// transient network error, an unreachable server).
struct ForgeRetryState: Sendable {
    static let initialDelay: TimeInterval = 30
    static let maxDelay: TimeInterval = 300

    var delay: TimeInterval = ForgeRetryState.initialDelay
    var nextAttempt: Date = .distantPast

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
