import Foundation
import Synchronization

/// ETags and bodies of recent GET responses, so a poll can ask "has this
/// changed?" (`If-None-Match`) instead of re-reading. GitHub does not charge
/// a 304 against the primary rate limit, and an idle fleet's polls are
/// almost all 304s.
///
/// Bounded: per-run jobs URLs come and go with every workflow run, so the
/// least recently used entry is evicted past `capacity`.
final class ConditionalGetCache: Sendable {
    private struct Entry: Sendable {
        var etag: String
        var body: Data
        var lastUsed: UInt64
    }

    private struct State: Sendable {
        var entries: [String: Entry] = [:]
        var clock: UInt64 = 0
    }

    private let capacity: Int
    private let state = Mutex(State())

    init(capacity: Int = 256) {
        self.capacity = capacity
    }

    /// The ETag to revalidate `url` with, if a body for it is cached.
    func etag(for url: String) -> String? {
        state.withLock { $0.entries[url]?.etag }
    }

    /// The cached body for a 304 answer, marking the entry used.
    func body(for url: String) -> Data? {
        state.withLock { state in
            guard var entry = state.entries[url] else { return nil }
            state.clock += 1
            entry.lastUsed = state.clock
            state.entries[url] = entry
            return entry.body
        }
    }

    func store(url: String, etag: String, body: Data) {
        let capacity = capacity
        state.withLock { state in
            state.clock += 1
            state.entries[url] = Entry(etag: etag, body: body, lastUsed: state.clock)
            while state.entries.count > capacity,
                let oldest = state.entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key
            {
                state.entries.removeValue(forKey: oldest)
            }
        }
    }

    var count: Int { state.withLock { $0.entries.count } }
}
