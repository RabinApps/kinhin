import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

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

    func testReportedExpiryDrivesRefreshNotTheFixedTTL() async throws {
        // A 10-minute token must be refetched even though the fallback TTL is an hour...
        let cache = RegistrationTokenCache(ttl: 3600, refreshMargin: 60)
        var fetches = 0
        for _ in 0..<2 {
            _ = try await cache.token(fetchExpiring: {
                fetches += 1
                return (token: "short", expiresAt: Date().addingTimeInterval(30))
            })
        }
        XCTAssertEqual(fetches, 2, "a token expiring inside the safety margin is never served from cache")

        // ...and a long-lived one is kept past the fixed TTL.
        let long = RegistrationTokenCache(ttl: 1, refreshMargin: 60)
        fetches = 0
        for _ in 0..<3 {
            _ = try await long.token(fetchExpiring: {
                fetches += 1
                return (token: "long", expiresAt: Date().addingTimeInterval(7200))
            })
        }
        XCTAssertEqual(fetches, 1)
    }

    func testMissingExpiryFallsBackToTheTTL() async throws {
        let cache = RegistrationTokenCache(ttl: 3600, refreshMargin: 60)
        var fetches = 0
        for _ in 0..<2 {
            _ = try await cache.token(fetchExpiring: {
                fetches += 1
                return (token: "t", expiresAt: nil)
            })
        }
        XCTAssertEqual(fetches, 1)
    }

    func testGitHubForgeReportsTheExpiryGitHubReturned() async throws {
        let forge = GitHubForge(
            credentials: .github(token: "t", scope: "acme/widgets"), labels: [], client: FakeGitHub())
        let minted = try await forge.mintRegistrationTokenExpiring()
        XCTAssertFalse(minted.token.isEmpty)
        XCTAssertNotNil(minted.expiresAt)
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
