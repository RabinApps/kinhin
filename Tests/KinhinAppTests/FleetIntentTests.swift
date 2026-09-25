import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class FleetIntentTests: XCTestCase {
    private final class FakeBridge: FleetIntentBridge {
        var current: FleetStatus
        var error: Error?
        private(set) var setPausedCalls: [Bool] = []

        init(_ status: FleetStatus) { current = status }

        func status() async throws -> FleetStatus {
            if let error { throw error }
            return current
        }

        func setPaused(_ paused: Bool) async throws {
            if let error { throw error }
            setPausedCalls.append(paused)
            current.paused = paused
        }

        func doctor() async -> DoctorReport { fatalError("not used") }
    }

    private var original: FleetIntentBridge!

    override func setUp() {
        super.setUp()
        original = FleetIntentEnvironment.bridge
    }

    override func tearDown() {
        FleetIntentEnvironment.bridge = original
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
}
