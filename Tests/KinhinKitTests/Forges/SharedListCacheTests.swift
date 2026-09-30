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
}
