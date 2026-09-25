import XCTest

@testable import KinhinKit

final class RegistrationTokenCacheTests: XCTestCase {
    func testTokenCacheFetchesOnceWhileFresh() async throws {
        let cache = RegistrationTokenCache(ttl: 3600, refreshMargin: 60)
        var fetches = 0
        _ = try await cache.token {
            fetches += 1
            return "t1"
        }
        _ = try await cache.token {
            fetches += 1
            return "t2"
        }
        XCTAssertEqual(fetches, 1)
    }

    func testTokenCacheRefetchesAfterInvalidation() async throws {
        let cache = RegistrationTokenCache(ttl: 3600, refreshMargin: 60)
        var fetches = 0
        _ = try await cache.token {
            fetches += 1; return "t1"
        }
        cache.invalidate()
        _ = try await cache.token {
            fetches += 1; return "t2"
        }
        XCTAssertEqual(fetches, 2)
    }
}
