import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Fleet tab's runtime diagram: which runtimes get a lane, what each
/// instance's icon-led row draws, and when a lane says idle.
final class FleetDiagramModelTests: XCTestCase {
    // MARK: - Fixtures

    /// A record with no runtime set (nil = tart on old records), so every
    /// fixture lands on the first lane — lanes render in RuntimeID
    /// declaration order, tart first.
    private func record(_ id: String, phase: VMPhase = .ready, runtime: String? = nil) -> VMRecord {
        var record = VMRecord(id: id, phase: phase)
        record.createdAt = Date()
        record.runtime = runtime
        return record
    }

    private func instance(for record: VMRecord) -> FleetDiagramModel.Instance {
        FleetDiagramModel(status: FleetStatus(records: [record])).lanes[0].instances[0]
    }

    // MARK: - Lanes

    func testEveryPhaseIsDescribedInWordsNotJustColour() {
        let busy = instance(for: record("kinhin-1", phase: .busy))
        XCTAssertEqual(busy.accessibilityText, "kinhin-1, busy, running a job")
        XCTAssertTrue(instance(for: record("a", phase: .ready)).phaseDescription.contains("ready"))
        XCTAssertTrue(instance(for: record("a", phase: .booting)).phaseDescription.contains("starting up"))
        XCTAssertEqual(instance(for: record("a", phase: .failed)).phaseDescription, "failed")
        var broken = record("kinhin-2", phase: .busy)
        broken.error = "boot timed out"
        let described = instance(for: broken)
        XCTAssertTrue(described.phaseDescription.contains("has an error"))
        XCTAssertTrue(described.accessibilityText.contains("boot timed out"), "the detail follows the phase")
    }

    func testNoStatusYieldsNoLanes() {
        XCTAssertTrue(FleetDiagramModel(status: nil).lanes.isEmpty, "no snapshot, no picture")
    }

    func testSinglePoolFleetShowsOneTartLaneWithNoCap() {
        let model = FleetDiagramModel(status: FleetStatus(records: [record("kinhin-1")]))
        XCTAssertEqual(model.lanes.map(\.id), [.tart])
        XCTAssertEqual(model.lanes[0].mark, "🍎")
        XCTAssertEqual(model.lanes[0].title, "Tart VMs (macOS)")
        XCTAssertNil(model.lanes[0].cap, "a single-pool fleet reports no per-runtime caps")
    }

    func testSinglePoolFleetCanServeAnyRuntime() {
        let model = FleetDiagramModel(status: FleetStatus(runtime: RuntimeID.docker.rawValue))
        XCTAssertEqual(model.lanes.map(\.id), [.docker])
        XCTAssertEqual(model.lanes[0].mark, "🐳")
        XCTAssertEqual(model.lanes[0].title, "Docker (Linux)")
    }

    func testMixedFleetLanesFollowTheRuntimeOrderWithCaps() {
        let model = FleetDiagramModel(status: FleetStatus(capacityByRuntime: ["docker": "2", "tart": "3"]))
        XCTAssertEqual(model.lanes.map(\.id), [.tart, .docker], "declaration order, not dictionary order")
        XCTAssertEqual(model.lanes.map(\.cap), [3, 2])
        XCTAssertEqual(model.lanes.map(\.title), ["Tart VMs (macOS)", "Docker (Linux)"])
        XCTAssertTrue(model.lanes.allSatisfy(\.isIdle), "configured but nothing running: every lane is idle")
    }

    func testLaneWithoutInstancesSaysIdle() {
        let lane = FleetDiagramModel(status: FleetStatus()).lanes[0]
        XCTAssertTrue(lane.isIdle)
        XCTAssertNil(lane.countText, "an idle lane says idle, not a count")
        XCTAssertTrue(lane.instances.isEmpty)
    }

    func testRecordsGroupByTheirRuntime() {
        let status = FleetStatus(
            records: [
                record("kinhin-a", phase: .busy, runtime: "tart"),
                record("kinhin-b"),  // nil runtime: an old record is a tart VM
                record("kinhin-c", runtime: "appleContainer"),
            ],
            capacityByRuntime: ["tart": "2", "appleContainer": "1"])
        let model = FleetDiagramModel(status: status)
        XCTAssertEqual(model.lanes.map(\.id), [.tart, .appleContainer])
        XCTAssertEqual(model.lanes[0].instances.map(\.id), ["kinhin-a", "kinhin-b"])
        XCTAssertEqual(model.lanes[1].instances.map(\.id), ["kinhin-c"])
        XCTAssertEqual(model.lanes[0].countText, "2 instances · cap 2")
    }

    func testInstanceOnAnUnconfiguredRuntimeStillGetsALane() {
        let model = FleetDiagramModel(
            status: FleetStatus(records: [record("kinhin-d", runtime: "host")]))
        XCTAssertEqual(
            model.lanes.map(\.id), [.tart, .host],
            "recovery can adopt an instance the config doesn't name — it must stay visible")
        XCTAssertTrue(model.lanes[0].isIdle, "the configured runtime is idle")
        XCTAssertEqual(model.lanes[1].instances.map(\.id), ["kinhin-d"])
        XCTAssertEqual(model.lanes[1].title, "Host (this Mac)")
    }

    func testInstancesWithinALaneKeepTheStatusOrder() {
        let model = FleetDiagramModel(
            status: FleetStatus(records: [record("kinhin-3"), record("kinhin-1"), record("kinhin-2")]))
        XCTAssertEqual(
            model.lanes[0].instances.map(\.id), ["kinhin-3", "kinhin-1", "kinhin-2"],
            "the rows read exactly like the old VM list did")
    }

    // MARK: - Icon rows

    func testInstanceIconsAndColorsFollowThePhase() {
        let busy = instance(for: record("kinhin-b", phase: .busy))
        XCTAssertEqual(busy.symbol, "bolt.fill")
        XCTAssertEqual(busy.style, .ok)

        let ready = instance(for: record("kinhin-r"))
        XCTAssertEqual(ready.symbol, "checkmark.circle")
        XCTAssertEqual(ready.style, .secondary)

        let booting = instance(for: record("kinhin-t", phase: .booting))
        XCTAssertEqual(booting.symbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(booting.style, .secondary)

        let deleting = instance(for: record("kinhin-x", phase: .deleting))
        XCTAssertEqual(deleting.symbol, "xmark.circle")

        let failed = instance(for: record("kinhin-f", phase: .failed))
        XCTAssertEqual(failed.symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(failed.style, .error)
    }

    func testAnErrorOnAnyPhaseReadsAsAFailure() {
        var record = record("kinhin-e")
        record.error = "boot timed out"
        let row = instance(for: record)
        XCTAssertEqual(row.symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(row.style, .error)
        XCTAssertTrue(row.hasError, "the row reads red")
        XCTAssertTrue(row.detail.contains("⚠︎ boot timed out"), row.detail)
    }

    func testOnlyInstancesThatCanHoldAJobOpenThePipeline() {
        XCTAssertFalse(instance(for: record("kinhin-r")).opensPipeline, "an idle VM has no pipeline")

        var assigned = record("kinhin-j", phase: .booting)
        assigned.job = "build"
        XCTAssertTrue(instance(for: assigned).opensPipeline, "a booting VM with a job queued has one")

        XCTAssertTrue(instance(for: record("kinhin-b", phase: .busy)).opensPipeline)
    }

    func testInstanceDetailCarriesTheRowFacts() {
        var record = record("kinhin-g", phase: .busy)
        record.job = "build"
        record.repos = ["acme/api", "acme/web"]
        record.usage = ResourceUsage(cpuPercent: 120, memoryUsedMB: 3276)
        let row = instance(for: record)
        XCTAssertEqual(row.title, "• kinhin-g — busy")
        XCTAssertFalse(row.hasError)
        XCTAssertTrue(row.detail.contains("2 repos"), row.detail)
        XCTAssertTrue(row.detail.contains("build"), row.detail)
        XCTAssertTrue(row.detail.contains("CPU 120%"), row.detail)
        XCTAssertTrue(row.detail.contains("RAM 3.2 GB"), row.detail)
        XCTAssertTrue(row.tooltip.hasPrefix("• kinhin-g — busy"), row.tooltip)
    }

    // MARK: - Counts

    func testCountsAggregateAcrossLanes() {
        let status = FleetStatus(
            records: [
                record("kinhin-1", phase: .busy, runtime: "tart"),
                record("kinhin-2", runtime: "tart"),
                record("kinhin-3", phase: .busy, runtime: "docker"),
            ],
            capacityByRuntime: ["tart": "4", "docker": "1"])
        let model = FleetDiagramModel(status: status)
        XCTAssertEqual(model.instanceCount, 3)
        XCTAssertEqual(model.busyCount, 2)
        XCTAssertEqual(model.lanes[1].countText, "1 instance · cap 1")
    }
}
