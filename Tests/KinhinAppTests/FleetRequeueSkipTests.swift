import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The new Fleet tab actions: pending state, backend dispatch, refresh after
/// success, and failure surfacing through AlertKit.
@MainActor
final class FleetRequeueSkipTests: XCTestCase {
    private var fleet: FleetController!
    private var fake: FakeFleetServing!
    private var alertTitles: [String] = []
    private var answer: NSApplication.ModalResponse = .alertFirstButtonReturn

    override func setUp() async throws {
        try await super.setUp()
        fake = FakeFleetServing()
        fleet = FleetController()
        fleet.service = fake
        fleet.daemonProbe = { false }  // never touch a real daemon socket
        alertTitles = []
        answer = .alertFirstButtonReturn
        AlertKit.runModal = { [unowned self] alert in
            alertTitles.append(alert.messageText)
            return answer
        }
    }

    override func tearDown() async throws {
        AlertKit.runModal = { $0.runModal() }
        fleet = nil
        fake = nil
        try await super.tearDown()
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out: \\(message)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func calls(_ name: String) -> Int { fake.calls.filter { $0 == name }.count }

    // MARK: - Pending state

    func testRequeueQueuedJobsMarksPendingUntilTheCommandAndRefreshComplete() async throws {
        fake.gated = true
        fleet.userRequeueQueuedJobs(for: .github)
        await waitUntil("pending set") { fleet.pendingFleetAction == .requeueQueuedJobs(for: .github) }
        XCTAssertEqual(fleet.pendingFleetAction, .requeueQueuedJobs(for: .github))

        fake.releaseGate()
        await waitUntil("pending cleared after refresh") { fleet.pendingFleetAction == nil }
        XCTAssertNil(fleet.pendingFleetAction)
        XCTAssertEqual(fleet.status?.queueDepth, 0, "the status refresh replays the new queue")
    }

    func testSkipQueuedJobsMarksPendingUntilTheCommandAndRefreshComplete() async throws {
        fake.gated = true
        fleet.userSkipQueuedJobs(for: .github)
        await waitUntil("pending set") { fleet.pendingFleetAction == .skipQueuedJobs(for: .github) }
        XCTAssertEqual(fleet.pendingFleetAction, .skipQueuedJobs(for: .github))

        fake.releaseGate()
        await waitUntil("pending cleared after refresh") { fleet.pendingFleetAction == nil }
        XCTAssertNil(fleet.pendingFleetAction)
        XCTAssertEqual(fleet.status?.queueDepth, 0, "the status refresh replays the drained queue")
    }

    func testRequeueQueuedJobsRejectsANewCommandWhileOneRuns() async throws {
        fake.gated = true
        fleet.userRequeueQueuedJobs(for: .github)
        await waitUntil("pending set") { fleet.pendingFleetAction == .requeueQueuedJobs(for: .github) }
        XCTAssertEqual(fleet.pendingFleetAction, .requeueQueuedJobs(for: .github))

        fleet.userRequeueQueuedJobs(for: .gitlab)
        // The UX contract is that a second click while a command is running is a no-op.
        // We assert the original pending action is untouched rather than asserting a thrown error.
        XCTAssertEqual(fleet.pendingFleetAction, .requeueQueuedJobs(for: .github))
        fake.releaseGate()
        await waitUntil("pending cleared") { fleet.pendingFleetAction == nil }
    }

    // MARK: - Backend dispatch

    func testRequeueQueuedJobsForgesTheBackendCall() async throws {
        try await fleet.requeueQueuedJobs(for: .github)
        XCTAssertEqual(calls("requeueQueuedJobs(github)"), 1)
    }

    func testSkipQueuedJobsForgesTheBackendCall() async throws {
        try await fleet.skipQueuedJobs(for: .github)
        XCTAssertEqual(calls("skipQueuedJobs(github)"), 1)
    }

    // MARK: - Failure surfacing

    func testRequeueQueuedJobsFailureIsAlertedAndClearsPending() async {
        fake.commandError = EngineError.forgeNotFound(.github)
        fleet.userRequeueQueuedJobs(for: .github)
        await waitUntil("alert") { !alertTitles.isEmpty }
        XCTAssertEqual(alertTitles, ["Couldn't requeue the queued jobs"])
        await waitUntil("pending clears") { fleet.pendingFleetAction == nil }
    }

    func testSkipQueuedJobsFailureIsAlerted() async {
        fake.commandError = EngineError.forgeNotFound(.github)
        fleet.userSkipQueuedJobs(for: .github)
        await waitUntil("alert") { !alertTitles.isEmpty }
        XCTAssertEqual(alertTitles, ["Couldn't skip the queued jobs"])
    }

    // MARK: - No backend

    func testRequeueQueuedJobsWithoutABackendThrowsNotSetUp() async {
        fleet.service = nil
        do {
            try await fleet.requeueQueuedJobs(for: .github)
            XCTFail("no backend must throw")
        } catch EngineError.fleetNotSetUp {
        } catch {
            XCTFail("\\(error)")
        }
    }

    func testSkipQueuedJobsWithoutABackendThrowsNotSetUp() async {
        fleet.service = nil
        do {
            try await fleet.skipQueuedJobs(for: .github)
            XCTFail("no backend must throw")
        } catch EngineError.fleetNotSetUp {
        } catch {
            XCTFail("\\(error)")
        }
    }
}
