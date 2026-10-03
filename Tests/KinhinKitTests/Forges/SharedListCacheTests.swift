import Synchronization
import XCTest

@testable import KinhinKit

final class SharedListCacheTests: XCTestCase {
    func testFreshListIsServedWithoutFetching() async throws {
        let cache = SharedListCache<Int>(ttl: 60)
        let fetches = Mutex(0)
        for _ in 0..<5 {
            let list = try await cache.elements {
                fetches.withLock { $0 += 1 }
                return [1, 2]
            }
            XCTAssertEqual(list, [1, 2])
        }
        XCTAssertEqual(fetches.withLock { $0 }, 1)
    }

    func testZeroTTLAlwaysFetches() async throws {
        let cache = SharedListCache<Int>(ttl: 0)
        let fetches = Mutex(0)
        for _ in 0..<3 {
            _ = try await cache.elements {
                fetches.withLock { $0 += 1 }
                return []
            }
        }
        XCTAssertEqual(fetches.withLock { $0 }, 3)
    }

    func testInvalidateForcesAFetch() async throws {
        let cache = SharedListCache<Int>(ttl: 60)
        _ = try await cache.elements { [1] }
        cache.invalidate()
        let list = try await cache.elements { [2] }
        XCTAssertEqual(list, [2])
    }

    func testFailuresAreNotCached() async throws {
        struct Boom: Error {}
        let cache = SharedListCache<Int>(ttl: 60)
        do {
            _ = try await cache.elements { throw Boom() }
            XCTFail("expected the fetch error to propagate")
        } catch is Boom {}
        let list = try await cache.elements { [3] }
        XCTAssertEqual(list, [3])
    }

    /// A fetch that started before an invalidation returns its result to its
    /// caller but must not store it as fresh: the next reader fetches again.
    func testFetchSpanningAnInvalidationIsNotStored() async throws {
        let cache = SharedListCache<Int>(ttl: 60)
        let stale = try await cache.elements {
            cache.invalidate()
            return [1]
        }
        XCTAssertEqual(stale, [1])
        let list = try await cache.elements { [2] }
        XCTAssertEqual(list, [2])
    }

    /// N readers arriving while a fetch is running share it: one API call.
    func testConcurrentReadersAfterExpiryShareOneFetch() async throws {
        let cache = SharedListCache<Int>(ttl: 0)  // always expired: every reader needs a fetch
        let fetches = Mutex(0)
        let release = Mutex(false)
        let results = try await withThrowingTaskGroup(of: [Int].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await cache.elements {
                        fetches.withLock { $0 += 1 }
                        while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
                        return [42]
                    }
                }
            }
            // Let all eight reach the cache while the first fetch is parked.
            try await Task.sleep(for: .milliseconds(200))
            release.withLock { $0 = true }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0 == [42] })
        XCTAssertEqual(fetches.withLock { $0 }, 1, "one fetch for all concurrent readers")
    }

    func testAFailureReachesEveryJoinedReaderAndIsNotCached() async throws {
        struct Boom: Error {}
        let cache = SharedListCache<Int>(ttl: 60)
        let release = Mutex(false)
        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    do {
                        _ = try await cache.elements {
                            while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
                            throw Boom()
                        }
                        return false
                    } catch is Boom { return true } catch { return false }
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
            release.withLock { $0 = true }
            return await group.reduce(into: 0) { $0 += $1 ? 1 : 0 }
        }
        XCTAssertEqual(failures, 3)
        let list = try await cache.elements { [9] }
        XCTAssertEqual(list, [9])
    }

    /// A reader after an invalidation must not join the outdated fetch.
    func testReaderAfterInvalidationStartsItsOwnFetch() async throws {
        let cache = SharedListCache<Int>(ttl: 60)
        let release = Mutex(false)
        let slow = Task {
            try await cache.elements {
                while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
                return [1]
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        cache.invalidate()
        let fresh = try await cache.elements { [2] }
        XCTAssertEqual(fresh, [2])
        release.withLock { $0 = true }
        let old = try await slow.value
        XCTAssertEqual(old, [1])
        let cached = try await cache.elements { [3] }
        XCTAssertEqual(cached, [2], "the outdated fetch did not overwrite the newer result")
    }
}
