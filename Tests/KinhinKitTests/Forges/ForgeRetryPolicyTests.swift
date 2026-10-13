import Foundation
import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The waits a retry loop asked for, recorded instead of slept.
private final class SleepLog: Sendable {
    let values = Mutex<[TimeInterval]>([])
}

/// The one retry policy shared by `ForgeTransport`, `GitHubClient` and
/// `GitHubScaleSetClient`.
final class ForgeRetryPolicyTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.example.com/x")!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers)!
    }

    // MARK: - Delay

    func testBackoffGrowsWithEqualJitterAndIsCapped() {
        var policy = ForgeRetryPolicy(baseDelay: 2, maxDelay: 10)
        policy.random = { 0 }
        XCTAssertEqual(policy.delay(forRetry: 1, requested: nil), 1, accuracy: 0.0001, "half of 2s when jitter is 0")
        XCTAssertEqual(policy.delay(forRetry: 2, requested: nil), 2, accuracy: 0.0001)
        policy.random = { 0.999999 }
        XCTAssertEqual(policy.delay(forRetry: 1, requested: nil), 2, accuracy: 0.001, "full 2s when jitter is 1")
        XCTAssertEqual(policy.delay(forRetry: 9, requested: nil), 10, accuracy: 0.001, "capped at maxDelay")
    }

    func testServerRequestedWaitIsHonoredAndNeverShorter() {
        var policy = ForgeRetryPolicy(maxDelay: 30)
        policy.random = { 0 }
        XCTAssertEqual(policy.delay(forRetry: 1, requested: 7), 7, accuracy: 0.0001)
        policy.random = { 0.5 }
        XCTAssertGreaterThan(policy.delay(forRetry: 1, requested: 7), 7, "jitter only adds")
        XCTAssertLessThanOrEqual(policy.delay(forRetry: 1, requested: 7), 8)
    }

    // MARK: - Verdicts

    func testPlainForbiddenIsNeverRetried() {
        XCTAssertEqual(ForgeRetryPolicy().verdict(for: response(403)), .fail)
        XCTAssertEqual(
            ForgeRetryPolicy().verdict(for: response(403, ["X-RateLimit-Remaining": "12"])), .fail,
            "budget left: a permissions error, not a limit")
    }

    func testSecondaryRateLimitForbiddenRetriesAfterRetryAfter() {
        XCTAssertEqual(ForgeRetryPolicy().verdict(for: response(403, ["Retry-After": "5"])), .retry(after: 5))
    }

    func testSpentBudgetWaitsForResetOnlyWhenItIsSoon() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let soon = response(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1000010"])
        XCTAssertEqual(ForgeRetryPolicy().verdict(for: soon, now: now), .retry(after: 10))
        let far = response(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1003600"])
        XCTAssertEqual(ForgeRetryPolicy().verdict(for: far, now: now), .fail, "an hour is the caller's to report")
    }

    func testTooManyRequestsAndServerErrorsRetry() {
        XCTAssertEqual(ForgeRetryPolicy().verdict(for: response(429)), .retry(after: nil))
        XCTAssertEqual(ForgeRetryPolicy().verdict(for: response(429, ["Retry-After": "3"])), .retry(after: 3))
        XCTAssertEqual(ForgeRetryPolicy().verdict(for: response(429, ["Retry-After": "600"])), .fail)
        XCTAssertEqual(ForgeRetryPolicy().verdict(for: response(502)), .retry(after: nil))
        XCTAssertEqual(ForgeRetryPolicy().verdict(for: response(503, ["Retry-After": "2"])), .retry(after: 2))
        XCTAssertEqual(ForgeRetryPolicy().verdict(for: response(400)), .fail)
        XCTAssertEqual(ForgeRetryPolicy().verdict(for: response(404)), .fail)
    }

    func testRetryAfterAcceptsAnHTTPDate() {
        let now = Date(timeIntervalSince1970: 784_111_777)  // Sun, 06 Nov 1994 08:49:37 GMT
        let http = response(429, ["Retry-After": "Sun, 06 Nov 1994 08:49:47 GMT"])
        XCTAssertEqual(try XCTUnwrap(ForgeRetryPolicy.requestedWait(http, now: now)), 10, accuracy: 0.5)
    }

    // MARK: - run

    func testRunDoesNotRetryNetworkErrorsWhenTurnedOff() async {
        let calls = Locked(0)
        var policy = ForgeRetryPolicy(retries: 3, baseDelay: 0.001)
        policy.retriesNetworkErrors = false
        do {
            let _: Int = try await policy.run {
                calls.withLock { $0 += 1 }
                throw URLError(.timedOut)
            }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testRunRetriesNetworkErrorsAndThenSucceeds() async throws {
        let calls = Locked(0)
        let policy = ForgeRetryPolicy(retries: 3, baseDelay: 0.001)
        let value: String = try await policy.run {
            let n = calls.withLock { n -> Int in
                n += 1
                return n
            }
            if n < 3 { throw URLError(.networkConnectionLost) }
            return .done("ok")
        }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(calls.withLock { $0 }, 3)
    }

    // MARK: - ForgeTransport

    private func transport(sleeps: SleepLog) -> ForgeTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        var transport = ForgeTransport(
            session: URLSession(configuration: config), forge: .gitlab, authorization: .privateToken("t"), retries: 3,
            baseDelay: 0.001)
        transport.sleep = { seconds in sleeps.values.withLock { $0.append(seconds) } }
        return transport
    }

    func testTransportDoesNotRetryAPlainForbidden() async {
        let calls = Locked(0)
        let sleeps = SleepLog()
        StubProtocol.handler = { _ in
            calls.withLock { $0 += 1 }
            return (403, Data("no scope".utf8), [:])
        }
        do {
            _ = try await transport(sleeps: sleeps).send("GET", URL(string: "https://git.example.com/x")!)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? ForgeAPIError, .forbidden(forge: .gitlab, why: "no scope"))
        }
        XCTAssertEqual(calls.withLock { $0 }, 1, "one request, no sleeps before the permissions error")
        XCTAssertTrue(sleeps.values.withLock { $0.isEmpty })
    }

    func testTransportHonorsRetryAfterOnRateLimitedResponses() async throws {
        let calls = Locked(0)
        let sleeps = SleepLog()
        StubProtocol.handler = { _ in
            let n = calls.withLock { n -> Int in
                n += 1
                return n
            }
            if n == 1 { return (403, Data("secondary".utf8), ["Retry-After": "4"]) }
            if n == 2 { return (429, Data(), ["Retry-After": "2"]) }
            return (200, Data("{}".utf8), [:])
        }
        _ = try await transport(sleeps: sleeps).send("GET", URL(string: "https://git.example.com/x")!)
        let waited = sleeps.values.withLock { $0 }
        XCTAssertEqual(waited.count, 2)
        XCTAssertGreaterThanOrEqual(waited[0], 4)
        XCTAssertGreaterThanOrEqual(waited[1], 2)
    }

    // MARK: - GitHubClient

    private func githubClient(sleeps: SleepLog) -> GitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        var client = GitHubClient(
            credentials: GitHubCredentials(token: "t", scope: "acme/widgets"),
            session: URLSession(configuration: config))
        client.retryPolicy.baseDelay = 0.001
        client.retryPolicy.sleep = { seconds in sleeps.values.withLock { $0.append(seconds) } }
        return client
    }

    func testGitHubPlainForbiddenSurfacesImmediately() async {
        let calls = Locked(0)
        let sleeps = SleepLog()
        StubProtocol.handler = { _ in
            calls.withLock { $0 += 1 }
            return (403, Data("Resource not accessible by personal access token".utf8), [:])
        }
        do {
            _ = try await githubClient(sleeps: sleeps).fetchRegistrationToken()
            XCTFail("should throw")
        } catch let error as GitHubError {
            guard case .forbidden = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertTrue(sleeps.values.withLock { $0.isEmpty }, "no backoff sleeps before a permissions error")
    }

    func testGitHubSecondaryRateLimitWaitsThenSucceeds() async throws {
        let calls = Locked(0)
        let sleeps = SleepLog()
        StubProtocol.handler = { _ in
            let n = calls.withLock { n -> Int in
                n += 1
                return n
            }
            if n == 1 { return (403, Data("secondary rate limit".utf8), ["Retry-After": "3"]) }
            return (200, Data("{\"total_count\":0,\"runners\":[]}".utf8), [:])
        }
        let runners = try await githubClient(sleeps: sleeps).listRunners()
        XCTAssertTrue(runners.isEmpty)
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sleeps.values.withLock { $0.first }), 3, "Retry-After honored")
    }

    func testGitHubServerErrorsRetryThenGiveUpWithTheLastError() async {
        let calls = Locked(0)
        let sleeps = SleepLog()
        StubProtocol.handler = { _ in
            calls.withLock { $0 += 1 }
            return (502, Data("bad gateway".utf8), [:])
        }
        do {
            _ = try await githubClient(sleeps: sleeps).listRunners()
            XCTFail("should throw")
        } catch let error as GitHubError {
            XCTAssertEqual(error, .http(502, "bad gateway"))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertEqual(calls.withLock { $0 }, 4, "first try plus three retries")
        XCTAssertEqual(sleeps.values.withLock { $0.count }, 3)
    }

    // MARK: - GitHubScaleSetClient

    private func scaleSetClient(sleeps: SleepLog) -> GitHubScaleSetClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        var client = GitHubScaleSetClient(
            credentials: GitHubCredentials(token: "t", scope: "acme/widgets"),
            session: URLSession(configuration: config))
        client.retryPolicy.baseDelay = 0.001
        client.retryPolicy.sleep = { seconds in sleeps.values.withLock { $0.append(seconds) } }
        return client
    }

    private var queueSession: GitHubScaleSetSession {
        GitHubScaleSetSession(
            sessionId: "s", messageQueueUrl: URL(string: "https://queue.example.invalid/messages")!,
            messageQueueAccessToken: "q")
    }

    func testMessagePollRetriesATransient5xx() async throws {
        let calls = Locked(0)
        let sleeps = SleepLog()
        StubProtocol.handler = { _ in
            let n = calls.withLock { n -> Int in
                n += 1
                return n
            }
            return n == 1 ? (503, Data(), [:]) : (202, Data(), [:])
        }
        let messages = try await scaleSetClient(sleeps: sleeps).pollMessages(
            session: queueSession, lastMessageId: nil, maxCapacity: 1)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertEqual(sleeps.values.withLock { $0.count }, 1)
    }

    func testMessagePollDoesNotRetryAPersistent401() async {
        let calls = Locked(0)
        StubProtocol.handler = { _ in
            calls.withLock { $0 += 1 }
            return (401, Data(), [:])
        }
        do {
            _ = try await scaleSetClient(sleeps: SleepLog()).pollMessages(
                session: queueSession, lastMessageId: nil, maxCapacity: 1)
            XCTFail("should throw")
        } catch {
            guard case GitHubScaleSetClientError.messageQueueTokenExpired = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testAckRetriesATransient5xx() async throws {
        let calls = Locked(0)
        StubProtocol.handler = { _ in
            let n = calls.withLock { n -> Int in
                n += 1
                return n
            }
            return n == 1 ? (500, Data(), [:]) : (204, Data(), [:])
        }
        try await scaleSetClient(sleeps: SleepLog()).ackMessage(session: queueSession, messageId: "7")
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testLongPollSessionOutlastsTheServersHold() {
        let poll = ForgeHTTP.longPollSession(nil).configuration
        XCTAssertGreaterThanOrEqual(poll.timeoutIntervalForRequest, 90, "GitHub holds a message poll ~50 s")
        XCTAssertGreaterThan(poll.timeoutIntervalForResource, poll.timeoutIntervalForRequest)
        XCTAssertEqual(ForgeHTTP.session(nil).configuration.timeoutIntervalForRequest, 30)
    }

    func testAnInjectedSessionServesThePollToo() {
        let injected = URLSession(configuration: .ephemeral)
        XCTAssertTrue(ForgeHTTP.longPollSession(injected) === injected)
    }
}
