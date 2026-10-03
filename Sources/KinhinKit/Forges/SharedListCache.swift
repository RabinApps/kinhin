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
/// invalidation cannot store its (now stale) result as fresh, and later
/// readers start a fresh fetch instead of joining the outdated one.
final class SharedListCache<Element: Sendable>: Sendable {
    private struct InFlight: Sendable {
        let id: UInt64
        let generation: Int
        let task: Task<[Element], Error>
    }

    private struct State: Sendable {
        var fetched: Date?
        var elements: [Element] = []
        var generation = 0
        /// The fetch readers join instead of starting their own (concurrent
        /// readers after a TTL expiry cost one call, not N).
        var inFlight: InFlight?
        var nextID: UInt64 = 0
    }

    private enum Step {
        case cached([Element])
        case join(Task<[Element], Error>)
    }

    private let ttl: TimeInterval
    private let state = Mutex(State())

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    /// The cached list while it is younger than `ttl`, else `fetch()`'s
    /// result (which then becomes the cached list). Readers that arrive while
    /// a fetch is running share its result; a failure reaches all of them and
    /// is not cached.
    func elements(fetch: @escaping @Sendable () async throws -> [Element]) async throws -> [Element] {
        let ttl = ttl
        let step = state.withLock { state -> Step in
            if let fetched = state.fetched, Date().timeIntervalSince(fetched) < ttl {
                return .cached(state.elements)
            }
            if let inFlight = state.inFlight, inFlight.generation == state.generation {
                return .join(inFlight.task)
            }
            state.nextID += 1
            let id = state.nextID
            let generation = state.generation
            let task = Task<[Element], Error> {
                do {
                    let fresh = try await fetch()
                    self.complete(id: id, generation: generation, result: fresh)
                    return fresh
                } catch {
                    self.complete(id: id, generation: generation, result: nil)
                    throw error
                }
            }
            state.inFlight = InFlight(id: id, generation: generation, task: task)
            return .join(task)
        }
        switch step {
        case .cached(let cached): return cached
        case .join(let task): return try await task.value
        }
    }

    /// Stores a successful result (unless an invalidation outdated it) and
    /// retires the in-flight record.
    private func complete(id: UInt64, generation: Int, result: [Element]?) {
        state.withLock { state in
            if state.inFlight?.id == id { state.inFlight = nil }
            guard let result, state.generation == generation else { return }
            state.fetched = Date()
            state.elements = result
        }
    }

    /// Forces the next read to fetch (after a write that changes the list).
    func invalidate() {
        state.withLock {
            $0.fetched = nil
            $0.generation += 1
        }
    }
}
