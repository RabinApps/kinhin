import XCTest

@testable import KinhinKit

final class WakeSignalTests: XCTestCase {
    private let clock = ContinuousClock()

    func testSleepsItsDurationWhenNobodySignals() async throws {
        let wake = WakeSignal()
        let elapsed = try await clock.measure { try await wake.sleep(for: .milliseconds(150)) }
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(140))
    }

    /// Ending one sleep (by its deadline) must not poison the next one: an
    /// AsyncStream-based wake would terminate and make every later sleep return at once.
    func testEverySleepAfterAnEarlierOneStillWaits() async throws {
        let wake = WakeSignal()
        for _ in 0..<3 {
            let elapsed = try await clock.measure { try await wake.sleep(for: .milliseconds(100)) }
            XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(90), "a later sleep must not return early")
        }
    }

    func testSignalWakesASleeperImmediately() async throws {
        let wake = WakeSignal()
        let sleeper = Task { try await ContinuousClock().measure { try await wake.sleep(for: .seconds(60)) } }
        try await Task.sleep(for: .milliseconds(100))
        wake.signal()
        let elapsed = try await sleeper.value
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testASignalWithNobodyWaitingWakesTheNextSleepOnce() async throws {
        let wake = WakeSignal()
        wake.signal()
        let first = try await clock.measure { try await wake.sleep(for: .seconds(60)) }
        XCTAssertLessThan(first, .seconds(2))
        let second = try await clock.measure { try await wake.sleep(for: .milliseconds(100)) }
        XCTAssertGreaterThanOrEqual(second, .milliseconds(90), "the signal was consumed")
    }

    func testCancellationThrows() async throws {
        let wake = WakeSignal()
        let sleeper = Task { try await wake.sleep(for: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(50))
        sleeper.cancel()
        do {
            try await sleeper.value
            XCTFail("a cancelled sleep must throw")
        } catch is CancellationError {}
    }
}
