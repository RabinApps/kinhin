import XCTest

@testable import KinhinKit

/// Runner starts that keep failing must not respawn in a tight loop: the
/// runtime waits 30 s, 1 min, 2 min … (cap 10 min) and a success clears it.
final class SpawnBackoffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testFirstFailureDoesNotBlockButTheSecondDoes() {
        var backoff = SpawnBackoff()
        XCTAssertEqual(backoff.recordFailure(.appleContainer, reason: "x", now: now), 0)
        XCTAssertNil(backoff.blockedUntil(.appleContainer, now: now))
        XCTAssertEqual(backoff.recordFailure(.appleContainer, reason: "x", now: now), 30)
        XCTAssertEqual(backoff.blockedUntil(.appleContainer, now: now), now.addingTimeInterval(30))
        XCTAssertEqual(backoff.blocked(now: now), [.appleContainer])
    }

    func testDelayDoublesAndCapsAtTenMinutes() {
        XCTAssertEqual(SpawnBackoff.delay(afterFailures: 1), 0)
        XCTAssertEqual(
            (2...8).map { SpawnBackoff.delay(afterFailures: $0) }, [30, 60, 120, 240, 480, 600, 600])
        XCTAssertEqual(SpawnBackoff.delay(afterFailures: 500), 600)
    }

    func testBackoffExpiresAndSuccessClearsIt() {
        var backoff = SpawnBackoff()
        backoff.recordFailure(.docker, reason: "a", now: now)
        backoff.recordFailure(.docker, reason: "b", now: now)
        XCTAssertNil(backoff.blockedUntil(.docker, now: now.addingTimeInterval(31)), "the wait is over")
        backoff.recordFailure(.docker, reason: "c", now: now.addingTimeInterval(31))
        XCTAssertEqual(
            backoff.blockedUntil(.docker, now: now.addingTimeInterval(32)), now.addingTimeInterval(31 + 60))
        backoff.recordSuccess(.docker)
        XCTAssertTrue(backoff.blocked(now: now).isEmpty)
        XCTAssertEqual(backoff.recordFailure(.docker, reason: "d", now: now), 0, "the streak restarts after a success")
    }

    func testRuntimesBackOffIndependently() {
        var backoff = SpawnBackoff()
        backoff.recordFailure(.appleContainer, reason: "x", now: now)
        backoff.recordFailure(.appleContainer, reason: "x", now: now)
        XCTAssertNil(backoff.blockedUntil(.tart, now: now))
        XCTAssertEqual(backoff.blocked(now: now), [.appleContainer])
    }

    func testSummaryNamesTheRuntimeWaitAndReason() {
        var backoff = SpawnBackoff()
        XCTAssertNil(backoff.summary(now: now))
        backoff.recordFailure(.appleContainer, reason: "exit 1: boom", now: now)
        backoff.recordFailure(.appleContainer, reason: "exit 1: boom", now: now)
        let line = backoff.summary(now: now) ?? ""
        XCTAssertTrue(line.hasPrefix("runner starts failing"), line)
        XCTAssertTrue(line.contains("appleContainer") && line.contains("30s") && line.contains("exit 1: boom"), line)
        XCTAssertNil(backoff.summary(now: now.addingTimeInterval(60)), "silent once the wait is over")
    }
}
