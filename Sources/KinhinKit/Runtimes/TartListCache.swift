import Foundation
import Synchronization

/// Shares one `tart list` answer between every caller in a process for a short while.
///
/// `tart list` is not a cheap read: for every local VM, tart runs `diskutil image info` on its disk
/// image to report its size, which takes several seconds with a handful of macOS images. On macOS
/// 27.2 each of those probes also leaves APFS container and volume objects behind in the kernel
/// (`AppleAPFSContainer`, `AppleAPFSVolume`, `APFSOSNumberAtomic`; `kalloc.type12.32` grows), and
/// the daemon's status, reconcile, usage and orphan passes used to call `tart list` back to back.
/// On a host with eight Tart VMs that exhausted the kernel zone map and panicked the Mac after
/// about 41 hours.
///
/// The cache keeps the kernel's work bounded by time instead of by how many passes ask:
/// - Concurrent callers share one in-flight `tart list` (single flight).
/// - A finished answer serves for `maxAge`.
/// - kinhin's own changes (`clone`, `set`, `run`, `stop`, `delete`, `pull`, `create`) call
///   `invalidate()`, so a caller never reads a listing from before kinhin changed the VMs.
///   A VM that stops on its own (an ephemeral guest powering off) shows up within `maxAge`.
/// - A failed listing is never cached.
public final class TartListCache: Sendable {
    /// How long one listing serves every caller. Below the default `poll_interval` (15s), so a
    /// reconcile tick never acts on a listing from the tick before.
    public static let defaultMaxAge: Duration = .seconds(10)

    private struct State {
        var vms: [TartVM]?
        var fetchedAt: ContinuousClock.Instant?
        var inFlight: Task<[TartVM], Error>?
        /// Bumped by `invalidate()`: a listing that started before a change is not stored.
        var generation = 0
    }

    private let state = Mutex(State())
    let maxAge: Duration

    public init(maxAge: Duration = TartListCache.defaultMaxAge) {
        self.maxAge = maxAge
    }

    /// One cache per tart binary, shared by every real `TartController` in this process.
    public static func shared(forBinary binary: String) -> TartListCache {
        registry.withLock { caches in
            if let cache = caches[binary] { return cache }
            let cache = TartListCache()
            caches[binary] = cache
            return cache
        }
    }

    private static let registry = Mutex<[String: TartListCache]>([:])

    /// The cached listing when it is fresh, else the in-flight one, else a new `fetch`.
    func list(fetch: @escaping @Sendable () async throws -> [TartVM]) async throws -> [TartVM] {
        let now = ContinuousClock.now
        let (cached, task, generation) = state.withLock { s -> ([TartVM]?, Task<[TartVM], Error>?, Int) in
            if let vms = s.vms, let at = s.fetchedAt, now - at < maxAge { return (vms, nil, s.generation) }
            if let running = s.inFlight { return (nil, running, s.generation) }
            let started = Task { try await fetch() }
            s.inFlight = started
            return (nil, started, s.generation)
        }
        if let cached { return cached }
        guard let task else { return try await fetch() }  // unreachable: one of the two is set
        do {
            let vms = try await task.value
            state.withLock { s in
                if s.inFlight == task { s.inFlight = nil }
                if s.generation == generation {
                    s.vms = vms
                    s.fetchedAt = ContinuousClock.now
                }
            }
            try Task.checkCancellation()
            return vms
        } catch {
            state.withLock { s in
                if s.inFlight == task { s.inFlight = nil }
            }
            throw error
        }
    }

    /// Forget the listing: the next `list` runs `tart list` again. A listing in flight is not
    /// awaited by later callers and its answer is not stored.
    public func invalidate() {
        state.withLock { s in
            s.generation += 1
            s.vms = nil
            s.fetchedAt = nil
            s.inFlight = nil
        }
    }
}
