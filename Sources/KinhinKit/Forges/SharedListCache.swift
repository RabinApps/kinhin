import Foundation
import Synchronization

/// A short-lived list shared by everything reading the same forge endpoint.
///
/// Every instance's exit watch lists the scope's runners each second; without
/// sharing, N live instances cost N API calls per second (GitHub's 5,000
/// requests/hour budget is gone with two busy VMs). With it, the whole fleet
/// costs one call per `ttl`. Failures are never cached: the next reader
/// fetches again.
///
/// `invalidate()` bumps a generation, so a fetch that started before the
/// invalidation cannot store its (now stale) result as fresh.
final class SharedListCache<Element: Sendable>: Sendable {
    private struct State: Sendable {
        var fetched: Date?
        var elements: [Element] = []
        var generation = 0
    }

    private let ttl: TimeInterval
    private let state = Mutex(State())

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    /// The cached list while it is younger than `ttl`, else `fetch()`'s
    /// result (which then becomes the cached list).
    func elements(fetch: () async throws -> [Element]) async throws -> [Element] {
        let ttl = ttl
        let lookup = state.withLock { state -> (cached: [Element]?, generation: Int) in
            guard let fetched = state.fetched, Date().timeIntervalSince(fetched) < ttl else {
                return (nil, state.generation)
            }
            return (state.elements, state.generation)
        }
        if let cached = lookup.cached { return cached }
        let fresh = try await fetch()
        state.withLock { state in
            guard state.generation == lookup.generation else { return }
            state.fetched = Date()
            state.elements = fresh
        }
        return fresh
    }

    /// Forces the next read to fetch (after a write that changes the list).
    func invalidate() {
        state.withLock {
            $0.fetched = nil
            $0.generation += 1
        }
    }
}
