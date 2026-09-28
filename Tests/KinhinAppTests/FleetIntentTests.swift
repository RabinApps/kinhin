import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class FleetIntentTests: XCTestCase {
    private final class FakeBridge: FleetIntentBridge {
        var current: FleetStatus
        var error: Error?
        private(set) var setPausedCalls: [Bool] = []
        private(set) var startCalls = 0
        private(set) var stopCalls = 0
        /// When set, start/stop flips `running` like the real backend would.
        var appliesStartStop = false

        init(_ status: FleetStatus) { current = status }

        func status() async throws -> FleetStatus {
            if let error { throw error }
            return current
        }

        func startFleet() async throws {
            if let error { throw error }
            startCalls += 1
            if appliesStartStop { current.running = true }
        }

        func stopFleet() async throws {
            if let error { throw error }
            stopCalls += 1
            if appliesStartStop { current.running = false }
        }

        func setPaused(_ paused: Bool) async throws {
            if let error { throw error }
            setPausedCalls.append(paused)
            current.paused = paused
        }

        func doctor() async -> DoctorReport { fatalError("not used") }
    }

    private let productionBridge: FleetIntentBridge = AppFleetIntentBridge()

    override func tearDown() {
        // The bridge is a static: restoring the previous test's fake would
        // chain stale fakes across tests — always restore production.
        FleetIntentEnvironment.bridge = productionBridge
        super.tearDown()
    }

    func testPauseIsIdempotent() async throws {
        let bridge = FakeBridge(FleetStatus(running: true))
        FleetIntentEnvironment.bridge = bridge
        _ = try await PauseFleetIntent().perform()
        _ = try await PauseFleetIntent().perform()
        XCTAssertEqual(bridge.setPausedCalls, [true])
    }

    func testResumeOnlyActsWhenPaused() async throws {
        let bridge = FakeBridge(FleetStatus(running: true, paused: true))
        FleetIntentEnvironment.bridge = bridge
        _ = try await ResumeFleetIntent().perform()
        _ = try await ResumeFleetIntent().perform()
        XCTAssertEqual(bridge.setPausedCalls, [false])
    }

    func testStoppedFleetIsNotToggled() async throws {
        let bridge = FakeBridge(FleetStatus(running: false))
        FleetIntentEnvironment.bridge = bridge
        _ = try await PauseFleetIntent().perform()
        XCTAssertTrue(bridge.setPausedCalls.isEmpty)
    }

    func testErrorsPropagate() async {
        let bridge = FakeBridge(FleetStatus(running: true))
        bridge.error = FleetAccessError.notSetUp
        FleetIntentEnvironment.bridge = bridge
        do {
            _ = try await FleetStatusIntent().perform()
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is FleetAccessError)
        }
    }

    // MARK: Start/Stop intents

    func testStartRunsOnlyWhenStopped() async throws {
        let bridge = FakeBridge(FleetStatus(running: false))
        bridge.appliesStartStop = true
        FleetIntentEnvironment.bridge = bridge
        _ = try await StartFleetIntent().perform()
        _ = try await StartFleetIntent().perform()
        XCTAssertEqual(bridge.startCalls, 1, "a second start on a running fleet is a no-op")
    }

    func testStopRunsOnlyWhenRunning() async throws {
        let bridge = FakeBridge(FleetStatus(running: true))
        bridge.appliesStartStop = true
        FleetIntentEnvironment.bridge = bridge
        _ = try await StopFleetIntent().perform()
        _ = try await StopFleetIntent().perform()
        XCTAssertEqual(bridge.stopCalls, 1, "a second stop on a stopped fleet is a no-op")
    }

    func testStartReportsInProgressWhenThePollDisagrees() async throws {
        // Start was issued but the follow-up status still reads stopped —
        // forge verification is still running. The dialog must say so rather
        // than claim a state that isn't true yet.
        let bridge = FakeBridge(FleetStatus(running: false))
        FleetIntentEnvironment.bridge = bridge
        let text = try await StartStopFleetAction.run(start: true)
        XCTAssertEqual(bridge.startCalls, 1)
        XCTAssertTrue(text.contains("in progress"), "got: \(text)")
    }

    func testStartReportsSuccessWhenThePollConfirms() async throws {
        let bridge = FakeBridge(FleetStatus(running: false))
        bridge.appliesStartStop = true
        FleetIntentEnvironment.bridge = bridge
        let text = try await StartStopFleetAction.run(start: true)
        XCTAssertTrue(text.hasPrefix("Started."), "got: \(text)")
    }

    func testStopReportsSuccessWhenThePollConfirms() async throws {
        let bridge = FakeBridge(FleetStatus(running: true))
        bridge.appliesStartStop = true
        FleetIntentEnvironment.bridge = bridge
        let text = try await StartStopFleetAction.run(start: false)
        XCTAssertTrue(text.hasPrefix("Stopped."), "got: \(text)")
    }
}
