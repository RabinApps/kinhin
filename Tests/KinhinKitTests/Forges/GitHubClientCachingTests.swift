import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The GitHub client shares its runner list (every exit watch lists runners
/// each second) and, in fine-grained fallback mode, the scope's repositories.
final class GitHubClientCachingTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func makeClient(scope: String) -> GitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return GitHubClient(
            credentials: GitHubCredentials(token: "test-token", scope: scope),
            session: URLSession(configuration: config)
        )
    }

    func testRepeatedRunnerListsShareOneRequest() async throws {
        let listCalls = Mutex(0)
        StubProtocol.handler = { request in
            listCalls.withLock { $0 += 1 }
            let body = """
                {"total_count":1,"runners":[{"id":1,"name":"kinhin-1","status":"online","busy":false,"labels":[]}]}
                """
            return (200, Data(body.utf8), [:])
        }
        let client = makeClient(scope: "acme/widgets")
        let copy = client  // forges hold copies; the cache is shared by reference
        for _ in 0..<5 {
            _ = try await client.listRunners()
            _ = try await copy.listRunners()
        }
        XCTAssertEqual(listCalls.withLock { $0 }, 1, "ten watch reads within the TTL must cost one request")
    }

    func testDeletingARunnerRefreshesTheList() async throws {
        let deleted = Mutex(false)
        StubProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                deleted.withLock { $0 = true }
                return (204, Data(), [:])
            }
            let runners =
                deleted.withLock { $0 }
                ? "[]" : #"[{"id":7,"name":"kinhin-7","status":"online","busy":false,"labels":[]}]"#
            return (200, Data(#"{"total_count":1,"runners":\#(runners)}"#.utf8), [:])
        }
        let client = makeClient(scope: "acme/widgets")
        let before = try await client.listRunners()
        XCTAssertEqual(before.map(\.id), [7])
        try await client.deleteRunner(id: 7)
        let after = try await client.listRunners()
        XCTAssertEqual(after.map(\.id), [], "a deleted runner must not linger in the cache")
    }

    func testFallbackReadsTheScopeRepositoriesOnceAcrossPolls() async throws {
        let repoListCalls = Mutex(0)
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/orgs/acme/actions/runs" {
                XCTFail("org runs endpoint must never be called")
                return (404, Data(#"{"message":"Not Found"}"#.utf8), [:])
            }
            if path == "/orgs/acme/repos" {
                repoListCalls.withLock { $0 += 1 }
                return (200, Data(#"[{"full_name":"acme/widgets"}]"#.utf8), [:])
            }
            if path == "/repos/acme/widgets/actions/runs" {
                return (200, Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8), [:])
            }
            XCTFail("unexpected path: \(path)")
            return (404, Data(), [:])
        }
        let client = makeClient(scope: "acme")
        for _ in 0..<3 {
            _ = try await client.queuedJobs(matching: ["self-hosted"])
            _ = try await client.runningJobs(matching: ["self-hosted"])
        }
        XCTAssertEqual(repoListCalls.withLock { $0 }, 1)
    }
}

// MARK: - Conditional requests and rate limits

extension GitHubClientCachingTests {
    func testUnchangedReadsRevalidateAndReuseTheCachedBody() async throws {
        let conditionalRequests = Mutex(0)
        StubProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"runs-v1\"" {
                conditionalRequests.withLock { $0 += 1 }
                return (304, Data(), ["ETag": "\"runs-v1\""])
            }
            let path = request.url?.path ?? ""
            if path == "/repos/acme/widgets/actions/runs" {
                let body = #"{"total_count":1,"workflow_runs":[{"id":9}]}"#
                return (200, Data(body.utf8), ["ETag": "\"runs-v1\""])
            }
            if path == "/repos/acme/widgets/actions/runs/9/jobs" {
                let body = #"{"jobs":[{"id":1,"run_id":9,"name":"build","status":"queued","labels":["kinhin"]}]}"#
                return (200, Data(body.utf8), [:])
            }
            XCTFail("unexpected path: \(path)")
            return (404, Data(), [:])
        }
        let client = makeClient(scope: "acme/widgets")
        let first = try await client.queuedJobs(matching: ["kinhin"])
        let second = try await client.queuedJobs(matching: ["kinhin"])
        XCTAssertEqual(first.map(\.jobID), [1])
        XCTAssertEqual(second.map(\.jobID), [1], "a 304 must read as the cached answer")
        XCTAssertEqual(conditionalRequests.withLock { $0 }, 1)
    }

    func testEveryResponseRecordsTheRateLimit() async throws {
        StubProtocol.handler = { _ in
            (
                200, Data(#"{"total_count":0,"runners":[]}"#.utf8),
                ["X-RateLimit-Remaining": "412", "X-RateLimit-Limit": "5000", "X-RateLimit-Reset": "1800000000"]
            )
        }
        let client = makeClient(scope: "acme/widgets")
        XCTAssertNil(client.rateLimit)
        _ = try await client.listRunners()
        let limit = try XCTUnwrap(client.rateLimit)
        XCTAssertEqual(limit.remaining, 412)
        XCTAssertEqual(limit.limit, 5000)
        XCTAssertEqual(limit.resetAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(limit.isLow)
    }
}
