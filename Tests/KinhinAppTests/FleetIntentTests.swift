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
        private(set) var deleteCalls: [String] = []
        /// When set, start/stop flips `running` like the real backend would.
        var appliesStartStop = false
        /// When set, delete removes the record like the real backend would.
        var appliesDelete = false

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

        func deleteVM(id: String) async throws {
            if let error { throw error }
            deleteCalls.append(id)
            if appliesDelete { current.records.removeAll { $0.id == id } }
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

    // MARK: Delete VM intent

    private func statusWithVM(_ id: String) -> FleetStatus {
        FleetStatus(running: true, records: [VMRecord(id: id, phase: .busy)])
    }

    func testDeleteRunsOnceForAnExistingVM() async throws {
        let bridge = FakeBridge(statusWithVM("vm-1"))
        bridge.appliesDelete = true
        FleetIntentEnvironment.bridge = bridge
        _ = try await DeleteVMAction.run(id: "vm-1")
        _ = try await DeleteVMAction.run(id: "vm-1")
        XCTAssertEqual(bridge.deleteCalls, ["vm-1"], "a second delete of a gone VM is a no-op")
    }

    func testDeleteUnknownVMIsANoOp() async throws {
        let bridge = FakeBridge(statusWithVM("vm-1"))
        FleetIntentEnvironment.bridge = bridge
        let text = try await DeleteVMAction.run(id: "nope")
        XCTAssertTrue(bridge.deleteCalls.isEmpty)
        XCTAssertTrue(text.contains("No VM named nope"), "got: \(text)")
    }

    func testDeleteReportsSuccessWhenThePollConfirms() async throws {
        let bridge = FakeBridge(statusWithVM("vm-1"))
        bridge.appliesDelete = true
        FleetIntentEnvironment.bridge = bridge
        let text = try await DeleteVMAction.run(id: "vm-1")
        XCTAssertEqual(bridge.deleteCalls, ["vm-1"])
        XCTAssertTrue(text.hasPrefix("Deleted VM vm-1."), "got: \(text)")
    }

    func testDeleteReportsInProgressWhenThePollStillListsTheVM() async throws {
        // Teardown is async — right after the command the record can still
        // be listed. The dialog must say so rather than claim a done deal.
        let bridge = FakeBridge(statusWithVM("vm-1"))
        FleetIntentEnvironment.bridge = bridge
        let text = try await DeleteVMAction.run(id: "vm-1")
        XCTAssertEqual(bridge.deleteCalls, ["vm-1"])
        XCTAssertTrue(text.contains("in progress"), "got: \(text)")
    }

    func testDeleteErrorsPropagate() async {
        let bridge = FakeBridge(statusWithVM("vm-1"))
        bridge.error = FleetAccessError.notSetUp
        FleetIntentEnvironment.bridge = bridge
        do {
            _ = try await DeleteVMAction.run(id: "vm-1")
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is FleetAccessError)
            XCTAssertTrue(bridge.deleteCalls.isEmpty)
        }
    }
}
