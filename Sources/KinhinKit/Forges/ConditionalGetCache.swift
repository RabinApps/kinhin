import Foundation
import Synchronization

/// ETags and bodies of recent GET responses, so a poll can ask "has this
/// changed?" (`If-None-Match`) instead of re-reading. GitHub does not charge
/// a 304 against the primary rate limit, and an idle fleet's polls are
/// almost all 304s.
///
/// Bounded: per-run jobs URLs come and go with every workflow run, so the
/// least recently used entry is evicted past `capacity` entries or
/// `byteCapacity` total body bytes (a few large list bodies must not pin
/// megabytes).
final class ConditionalGetCache: Sendable {
    private struct Entry: Sendable {
        var etag: String
        var body: Data
        var lastUsed: UInt64
    }

    private struct State: Sendable {
        var entries: [String: Entry] = [:]
        var clock: UInt64 = 0
        var bytes = 0
    }

    private let capacity: Int
    private let byteCapacity: Int
    private let state = Mutex(State())

    init(capacity: Int = 256, byteCapacity: Int = 8 * 1024 * 1024) {
        self.capacity = capacity
        self.byteCapacity = byteCapacity
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
        let byteCapacity = byteCapacity
        state.withLock { state in
            state.clock += 1
            if let previous = state.entries[url] { state.bytes -= previous.body.count }
            state.entries[url] = Entry(etag: etag, body: body, lastUsed: state.clock)
            state.bytes += body.count
            // Evict least recently used first; the entry just stored goes
            // last (a single body over the byte cap is not kept at all).
            while state.entries.count > capacity || state.bytes > byteCapacity,
                let oldest = state.entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key
            {
                if let removed = state.entries.removeValue(forKey: oldest) { state.bytes -= removed.body.count }
            }
        }
    }

    var count: Int { state.withLock { $0.entries.count } }
    var totalBytes: Int { state.withLock { $0.bytes } }
}
