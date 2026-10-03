import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Fleet tab's Detail page: filter behavior, breakdown rendering, and the
/// drill-down of a selected VM's lifecycle.
@MainActor
final class FleetDetailModelTests: XCTestCase {
    private var controller: FleetController!
    private var fake: FakeFleetServing!
    private var model: FleetDetailModel!

    override func setUp() async throws {
        try await super.setUp()
        fake = FakeFleetServing()
        controller = FleetController()
        controller.service = fake
        controller.daemonProbe = { false }
        model = FleetDetailModel(controller: controller)
    }

    override func tearDown() async throws {
        controller = nil
        fake = nil
        model = nil
        try await super.tearDown()
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out: \\(message)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func records(_ ids: String...) -> [VMRecord] {
        ids.map { VMRecord(id: $0, phase: .ready) }
    }

    private func record(id: String, phase: VMPhase = .ready, repos: [String]? = nil) -> VMRecord {
        var r = VMRecord(id: id, phase: phase)
        r.repos = repos
        return r
    }

    // MARK: - Filter behavior

    func testAllShowsEveryRecord() async {
        let status = FleetStatus(records: records("a", "b"))
        controller.status = status
        await model.refresh()
        XCTAssertEqual(model.modeText, "All")
        XCTAssertEqual(model.records.map(\.id), ["a", "b"])
    }

    func testQueuedFiltersToReadyRecords() async {
        var status = FleetStatus(records: [VMRecord(id: "busy", phase: .busy), VMRecord(id: "ready", phase: .ready)])
        controller.status = status
        model.mode = .queued
        await model.refresh()
        XCTAssertEqual(model.records.map(\.id), ["ready"])
        XCTAssertEqual(model.modeText, "Queued")
    }

    func testRunningFiltersToBusyRecords() async {
        var status = FleetStatus(records: [VMRecord(id: "idle", phase: .ready), VMRecord(id: "busy", phase: .busy)])
        controller.status = status
        model.mode = .running
        await model.refresh()
        XCTAssertEqual(model.records.map(\.id), ["busy"])
    }

    func testCancelledFiltersToFailedRecords() async {
        var status = FleetStatus(records: [VMRecord(id: "ok", phase: .ready), VMRecord(id: "failed", phase: .failed)])
        controller.status = status
        model.mode = .cancelled
        await model.refresh()
        XCTAssertEqual(model.records.map(\.id), ["failed"])
        XCTAssertEqual(model.modeText, "Cancelled")
    }

    // MARK: - Breakdown rendering

    func testBreakdownGroupsQueuedJobsByRepo() async {
        var status = FleetStatus(
            records: [
                record(id: "a", phase: .ready, repos: ["alpha/one"]),
                record(id: "b", phase: .ready, repos: ["alpha/one"]),
                record(id: "c", phase: .ready, repos: ["beta/two"]),
            ])
        controller.status = status
        await model.refresh()
        XCTAssertTrue(model.breakdownText.contains("Queued: alpha/one ×2"))
        XCTAssertTrue(model.breakdownText.contains("beta/two ×1"))
    }

    func testBreakdownGroupsRunningJobsByRepo() async {
        var status = FleetStatus(
            records: [
                record(id: "a", phase: .busy, repos: ["alpha/one"]),
                record(id: "b", phase: .busy, repos: ["beta/two"]),
            ])
        controller.status = status
        await model.refresh()
        XCTAssertTrue(model.breakdownText.contains("Running: alpha/one ×1"))
        XCTAssertTrue(model.breakdownText.contains("beta/two ×1"))
    }

    func testEmptyNoteWhenThereAreNoRecords() async {
        controller.status = FleetStatus(records: [])
        await model.refresh()
        XCTAssertTrue(model.noWorkText.contains("No VMs yet"))
    }

    // MARK: - Drill-down

    func testSelectVMCarriesTheIDIntoTheDetailPane() async {
        controller.status = FleetStatus(records: records("kinhin-a"))
        await model.refresh()
        model.selectVM("kinhin-a")
        let detail = model.vmDetail(for: "kinhin-a")
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.id, "kinhin-a")
        XCTAssertEqual(detail?.phase, .ready)
    }

    func testSelectedVMDoesNotShowInTheEmptyDetailPane() {
        XCTAssertNil(model.vmDetail(for: "does-not-exist"))
    }

    // MARK: - Round trip through the controller

    func testRefreshRePublishesTheSnapshot() async {
        controller.status = FleetStatus(records: records("kinhin-a"))
        await model.refresh()
        XCTAssertEqual(model.records.map(\.id), ["kinhin-a"])
    }
}
