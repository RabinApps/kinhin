import XCTest

@testable import KinhinKit

final class ConditionalGetCacheTests: XCTestCase {
    func testStoresTheETagAndBodyPerURL() {
        let cache = ConditionalGetCache()
        XCTAssertNil(cache.etag(for: "u"))
        cache.store(url: "u", etag: "\"v1\"", body: Data("a".utf8))
        XCTAssertEqual(cache.etag(for: "u"), "\"v1\"")
        XCTAssertEqual(cache.body(for: "u"), Data("a".utf8))
        cache.store(url: "u", etag: "\"v2\"", body: Data("b".utf8))
        XCTAssertEqual(cache.etag(for: "u"), "\"v2\"")
    }

    func testEvictsTheLeastRecentlyUsedPastCapacity() {
        let cache = ConditionalGetCache(capacity: 2)
        cache.store(url: "a", etag: "1", body: Data())
        cache.store(url: "b", etag: "2", body: Data())
        _ = cache.body(for: "a")  // a is now more recent than b
        cache.store(url: "c", etag: "3", body: Data())
        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.etag(for: "a"))
        XCTAssertNil(cache.etag(for: "b"))
        XCTAssertNotNil(cache.etag(for: "c"))
    }

    func testTotalBodyBytesAreCappedEvictingLeastRecentlyUsed() {
        let cache = ConditionalGetCache(capacity: 100, byteCapacity: 100)
        cache.store(url: "a", etag: "1", body: Data(count: 40))
        cache.store(url: "b", etag: "2", body: Data(count: 40))
        _ = cache.body(for: "a")  // a is now newer than b
        cache.store(url: "c", etag: "3", body: Data(count: 40))
        XCTAssertNil(cache.etag(for: "b"), "the least recently used body is evicted past the byte cap")
        XCTAssertNotNil(cache.etag(for: "a"))
        XCTAssertNotNil(cache.etag(for: "c"))
        XCTAssertLessThanOrEqual(cache.totalBytes, 100)
        cache.store(url: "a", etag: "9", body: Data(count: 10))  // replacing adjusts the total
        XCTAssertEqual(cache.totalBytes, 50)
        cache.store(url: "huge", etag: "h", body: Data(count: 500))
        XCTAssertNil(cache.etag(for: "huge"), "one body over the cap is not retained")
        XCTAssertLessThanOrEqual(cache.totalBytes, 100)
    }
}
