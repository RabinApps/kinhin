import XCTest

@testable import KinhinKit

final class HealingDeadlineTests: XCTestCase {
    func testReturnsTheResultInTime() async throws {
        let value = try await HealingDeadline.run(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testAnOperationThatIgnoresCancellationStillTimesOut() async {
        let started = Date()
        do {
            _ = try await HealingDeadline.run(seconds: 0.1) { () -> Int in
                // Never checks for cancellation: a task group would wait for it.
                let end = Date().addingTimeInterval(3)
                while Date() < end { await Task.yield() }
                return 1
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not answer"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
