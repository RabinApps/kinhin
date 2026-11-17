import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
@testable import kinhin_app

/// The redesigned Fleet page's display state: header chip, banners, status block, notes, queued work.
@MainActor
final class FleetPageModelTests: MainWindowTestCase {
    private func running(_ configure: (inout FleetStatus) -> Void = { _ in }) -> FleetStatus {
        var status = FleetStatus()
        status.running = true
        status.queueDepth = 3
        status.desired = 4
        status.capacityCap = 6
        status.jobCapacity = 8
        configure(&status)
        return status
    }

    func testHeadlineMatchesTheDesign() {
        fleet.status = running()
        XCTAssertEqual(models.fleetModel.statusLines.first, "Queue 3 · Desired 4 · Cap 6 · 8 job slots")
        XCTAssertTrue(models.fleetModel.showsStatusBlock)
    }

    func testHeadlineOmitsJobSlotsWhenUnknown() {
        fleet.status = running { $0.jobCapacity = 0 }
        XCTAssertEqual(models.fleetModel.statusLines.first, "Queue 3 · Desired 4 · Cap 6")
    }

    func testStatusBlockIsCappedAtFiveLinesAndExcludesTheAutoResumeLine() {
        fleet.status = running {
            $0.paused = true
            $0.autoResume = true
            $0.queueByRepo = ["acme/api": 2, "acme/web": 1]
        }
        let lines = models.fleetModel.statusLines
        XCTAssertLessThanOrEqual(lines.count, 5)
        XCTAssertFalse(lines.contains { $0.hasPrefix("⏳") }, "the auto-resume line is the note above the block")
        XCTAssertTrue(lines.contains { $0.contains("acme/api ×2") }, "\(lines)")
        XCTAssertNotNil(models.fleetModel.pausedAutoResumeNote)
    }

    func testStateChipTracksTheState() {
        fleet.status = running()
        XCTAssertEqual(models.fleetModel.stateChip.text, "Running")
        XCTAssertEqual(models.fleetModel.stateChip.tone, .ok)
        fleet.status = running { $0.paused = true }
        XCTAssertEqual(models.fleetModel.stateChip.text, "Paused")
        XCTAssertEqual(models.fleetModel.stateChip.tone, .warn)
        fleet.status = FleetStatus()
        XCTAssertEqual(models.fleetModel.stateChip.text, "Stopped")
        XCTAssertNotNil(models.fleetModel.stoppedNote)
        XCTAssertFalse(models.fleetModel.showsStatusBlock)
    }

    func testNeedsSetupShowsOnlyTheNote() {
        fleet.service = nil
        fleet.status = nil
        let model = models.fleetModel
        XCTAssertEqual(model.stateChip.text, "Needs setup")
        XCTAssertTrue(model.showsOnlyNote)
        XCTAssertTrue(model.pageNote?.hasPrefix("Needs setup — finish the first-run wizard") == true)
    }

    func testBannersAreOrderedDiskThenProblemsThenStaleDaemon() {
        fleet.status = running {
            $0.diskPressureNotice = "Disk is almost full — new VMs are held until space frees up."
        }
        fleet.staleDaemonPlist = "Stale daemon LaunchAgent"
        let rows = models.fleetModel.bannerRows
        XCTAssertEqual(rows.map(\.kind), [.diskPressure, .staleDaemon])
        XCTAssertEqual(rows.map(\.banner), [.warn, .warn])
    }

    func testNoBannersWhenThereIsNothingToSay() {
        fleet.status = running()
        XCTAssertTrue(models.fleetModel.bannerRows.isEmpty)
    }

    func testImageNoticeIsSurfaced() {
        fleet.status = running { $0.imageNotice = "Baking image for acme/api" }
        XCTAssertEqual(models.fleetModel.imageNotice, "Baking image for acme/api")
    }

    func testJobRowsSplitTitleAndLocation() {
        let model = models.fleetModel
        let solo = FleetModel.JobRow(
            vmID: "runner-a1", runner: "runner-a1", job: "build", repo: "acme/web", phase: .busy, showsRunner: false)
        XCTAssertEqual(model.jobTitle(for: solo), "build — acme/web")
        XCTAssertEqual(model.jobLocation(for: solo), "runner-a1 · busy")
        let multi = FleetModel.JobRow(
            vmID: "vm-b1", runner: "runner 1", job: "test", repo: nil, phase: .busy, showsRunner: true)
        XCTAssertEqual(model.jobTitle(for: multi), "test")
        XCTAssertEqual(model.jobLocation(for: multi), "vm-b1 · runner 1 · busy")
    }

    func testQueueSummaryCountsAndSplitsByRepo() {
        fleet.status = running {
            $0.queueDepth = 3
            $0.queueByRepo = ["acme/api": 2, "acme/web": 1]
        }
        XCTAssertEqual(models.fleetModel.queueSummary, "3 queued · acme/api ×2, acme/web ×1")
        fleet.status = running { $0.queueDepth = 0 }
        XCTAssertEqual(models.fleetModel.queueSummary, "0 queued")
    }

    func testNoForgeRowsWithoutAnEngine() {
        fleet.status = running()
        XCTAssertTrue(models.fleetModel.forgeRows.isEmpty)
        XCTAssertFalse(models.fleetModel.isDaemonMode, "no backend at all is not daemon mode")
    }
}
