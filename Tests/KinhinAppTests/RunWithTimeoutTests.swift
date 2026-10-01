import XCTest

@testable import kinhin_app

final class RunWithTimeoutTests: XCTestCase {
    func testReturnsTrueWhenTheBodyFinishesInTime() async {
        let finished = await runWithTimeout(.seconds(5)) {}
        XCTAssertTrue(finished)
    }

    func testReturnsFalseWhenTheBodyOutlastsTheTimeout() async {
        let started = ContinuousClock.now
        let finished = await runWithTimeout(.milliseconds(50)) {
            // Ignores cancellation on purpose: it must not hold the caller.
            try? await Task.sleep(for: .seconds(2))
        }
        XCTAssertFalse(finished)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "the caller isn't held for the slow body")
    }

    func testResumesExactlyOnceWhenBothFinishTogether() async {
        for _ in 0..<50 {
            _ = await runWithTimeout(.milliseconds(1)) { try? await Task.sleep(for: .milliseconds(1)) }
        }
    }
}
