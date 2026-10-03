import Synchronization
import XCTest

@testable import KinhinKit

final class BoundedConcurrencyTests: XCTestCase {
    func testResultsKeepInputOrderWhateverTheCompletionOrder() async throws {
        let outputs = try await boundedMap(Array(0..<12), limit: 4) { value -> Int in
            // Later items finish first.
            try await Task.sleep(for: .milliseconds((12 - value) * 3))
            return value * 10
        }
        XCTAssertEqual(outputs, (0..<12).map { $0 * 10 })
    }

    func testNeverRunsMoreThanLimitAtOnce() async throws {
        let running = Mutex((current: 0, peak: 0))
        _ = try await boundedMap(Array(0..<20), limit: 3) { _ -> Int in
            running.withLock {
                $0.current += 1
                $0.peak = max($0.peak, $0.current)
            }
            try await Task.sleep(for: .milliseconds(10))
            running.withLock { $0.current -= 1 }
            return 0
        }
        let peak = running.withLock { $0.peak }
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 1, "work actually overlapped")
    }

    func testTheEarliestFailingItemsErrorIsThrownAndNotACancellation() async {
        struct Bad: Error, Equatable { let index: Int }
        do {
            _ = try await boundedMap(Array(0..<8), limit: 4) { value -> Int in
                if value == 2 || value == 3 {
                    try await Task.sleep(for: .milliseconds(5))
                    throw Bad(index: value)
                }
                try await Task.sleep(for: .milliseconds(200))
                return value
            }
            XCTFail("expected a failure")
        } catch let error as Bad {
            XCTAssertEqual(error, Bad(index: 2))
        } catch {
            XCTFail("a sibling's cancellation masked the real error: \(error)")
        }
    }

    func testEmptyAndSingleInputs() async throws {
        let none = try await boundedMap([Int](), limit: 4) { $0 }
        XCTAssertEqual(none, [])
        let one = try await boundedMap([7], limit: 4) { $0 + 1 }
        XCTAssertEqual(one, [8])
    }
}
