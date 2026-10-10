import Foundation
import Synchronization

/// A short-lived, shared copy of each account's runner list.
///
/// Every runner watch polls the forge's runner list (one call per second per
/// instance), so N instances cost N API calls a second against one rate
/// limit. The watchers read this directory instead: one list per account per
/// `ttl`, concurrent misses share a single call.
///
/// A cached list can only be *older* than the truth, never wrong about what
/// already happened (an ephemeral runner that left does not come back), so
/// reading it is safe for observation. Anything that *acts* on "the runner is
/// gone" or "the runner is idle" must confirm with `freshRunners(of:)`, which
/// always asks the forge and refreshes the cache for everyone else.
final class RunnerDirectory: Sendable {
    private struct Entry {
        var runners: [ForgeRunner]
        var fetchedAt: ContinuousClock.Instant
    }

    private struct Flight {
        var task: Task<[ForgeRunner], Error>
        var startedAt: ContinuousClock.Instant
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var inflight: [String: Flight] = [:]
    }

    private let state = Mutex(State())
    let ttl: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    init(ttl: Duration, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.ttl = ttl
        self.now = now
    }

    /// The account's runners, at most `ttl` old. A miss asks the forge once
    /// however many watchers miss together.
    func runners(of forge: Forge) async throws -> [ForgeRunner] {
        let account = forge.account
        let cached = state.withLock { state -> [ForgeRunner]? in
            guard let entry = state.entries[account], now() - entry.fetchedAt < ttl else { return nil }
            return entry.runners
        }
        if let cached { return cached }
        return try await fetch(forge, joiningInflight: true)
    }

    /// The account's runners as the forge reports them right now (bypassing
    /// the cache, which it refreshes). Use before acting on absence or idleness.
    func freshRunners(of forge: Forge) async throws -> [ForgeRunner] {
        try await fetch(forge, joiningInflight: false)
    }

    /// Drops the account's cached list (a token or forge swap).
    func invalidate(account: String) {
        state.withLock { _ = $0.entries.removeValue(forKey: account) }
    }

    private func fetch(_ forge: Forge, joiningInflight: Bool) async throws -> [ForgeRunner] {
        let account = forge.account
        // A call already in flight started before this one asked, so a caller
        // needing a current answer must not share it. The answer describes the
        // moment the call started, not the (possibly slow) moment it arrived.
        let flight = state.withLock { state -> Flight in
            if joiningInflight, let running = state.inflight[account] { return running }
            // A fresh read must also get past the forge's own short list cache.
            let flight = Flight(
                task: Task { joiningInflight ? try await forge.runners() : try await forge.freshRunners() },
                startedAt: now())
            state.inflight[account] = flight
            return flight
        }
        let runners: [ForgeRunner]
        do {
            runners = try await flight.task.value
        } catch {
            state.withLock { state in
                if state.inflight[account]?.task == flight.task { state.inflight[account] = nil }
            }
            throw error
        }
        state.withLock { state in
            if state.inflight[account]?.task == flight.task { state.inflight[account] = nil }
            // Never replace a newer answer with an older one that landed late.
            if let existing = state.entries[account], existing.fetchedAt > flight.startedAt { return }
            state.entries[account] = Entry(runners: runners, fetchedAt: flight.startedAt)
        }
        // The shared fetch is unstructured: the caller's own cancellation
        // still ends the caller's wait.
        try Task.checkCancellation()
        return runners
    }
}
