import XCTest
import AppKit
import KinhinKit
@testable import kinhin_app

@MainActor
final class StatusRenderingTests: XCTestCase {
    private var delegate: AppDelegate!
    private var menu: NSMenu!
    private var originalItems: [NSMenuItem] = []

    override func setUp() {
        super.setUp()
        delegate = AppDelegate()
        menu = delegate.buildMenu()
        delegate.menu = menu // rebuildVMSection mutates the stored menu
        originalItems = menu.items
    }

    // MARK: status-bar title

    func testTitleForStoppedFleet() {
        XCTAssertEqual(delegate.statusTitle(for: FleetStatus()), "○")
    }

    func testTitleForRunningIdleFleet() {
        var status = FleetStatus()
        status.running = true
        XCTAssertEqual(delegate.statusTitle(for: status), "○")
    }

    func testTitleForPausedFleet() {
        var status = FleetStatus()
        status.running = true
        status.paused = true
        XCTAssertEqual(delegate.statusTitle(for: status), "○⏸")
    }

    func testTitleCountsOnlyActiveVMs() {
        var status = FleetStatus()
        status.running = true
        status.records = [
            record(phase: .busy),
            record(phase: .ready),
            record(phase: .failed),   // terminal — not active
            record(phase: .deleting), // terminal — not active
        ]
        XCTAssertEqual(delegate.statusTitle(for: status), "○ 2")
    }

    // MARK: status line

    func testLineForStoppedFleet() {
        XCTAssertTrue(delegate.statusLine(for: FleetStatus()).hasPrefix("Stopped — queue 0 · desired 0 · cap 0"))
    }

    func testLineStateWords() {
        var status = FleetStatus()
        status.running = true
        XCTAssertTrue(delegate.statusLine(for: status).hasPrefix("Running"))
        status.paused = true
        XCTAssertTrue(delegate.statusLine(for: status).hasPrefix("Paused"))
    }

    func testLineOmitsJobSlotsWhenZero() {
        let line = delegate.statusLine(for: FleetStatus())
        XCTAssertFalse(line.contains("job slots"))

        var status = FleetStatus()
        status.jobCapacity = 6
        XCTAssertTrue(delegate.statusLine(for: status).contains("· 6 job slots"))
    }

    func testLineAppendsTopTwoQueuedRepos() {
        var status = FleetStatus()
        status.queueDepth = 6
        status.queueByRepo = [
            "alpha/one": 3, "beta/two": 2, "gamma/three": 1,
        ]
        let line = delegate.statusLine(for: status)
        XCTAssertTrue(line.contains("\n  ↳ alpha/one ×3, beta/two ×2"), "top 2 by depth, sorted: \(line)")
        XCTAssertFalse(line.contains("gamma"), "only the top 2 repos appear: \(line)")
    }

    func testLineAppendsRunningReposOnlyWhenActive() {
        var status = FleetStatus()
        status.runningByRepo = ["alpha/one": 2]
        XCTAssertFalse(delegate.statusLine(for: status).contains("▶"))

        status.records = [record(phase: .busy)]
        XCTAssertTrue(delegate.statusLine(for: status).contains("\n  ▶ alpha/one ×2"))
    }

    func testLineHidesPerRepoBreakdownsForSingleRepoFleet() {
        var status = FleetStatus()
        status.queueDepth = 1
        status.queueByRepo = nil
        XCTAssertFalse(delegate.statusLine(for: status).contains("↳"))
    }

    // MARK: apply(status:) wiring

    func testApplyUpdatesTitleAndStatusLineItem() {
        var status = FleetStatus()
        status.running = true
        status.paused = true
        status.queueDepth = 2
        status.desired = 1
        status.capacityCap = 3
        status.jobCapacity = 4

        delegate.apply(status: status)

        XCTAssertEqual(menu.items.first { $0.identifier?.rawValue == "statusLine" }?.title,
                       delegate.statusLine(for: status))
        XCTAssertEqual(delegate.lastStatus, status, "the poll caches the latest status for the main window")
    }

    func testApplyWithoutStatusShowsNeedsSetup() {
        delegate.apply(status: nil)
        XCTAssertEqual(menu.items.first { $0.identifier?.rawValue == "statusLine" }?.title,
                       "Needs setup — open the Setup tab")
        XCTAssertNil(delegate.lastStatus)
    }

    // MARK: VM section rebuild

    func testVMSectionListsEachRecordWithDetails() {
        var busy = record(phase: .busy)
        busy.job = "build"
        busy.repos = ["alpha/one", "beta/two"]
        var failed = record(phase: .failed)
        failed.error = "boot timed out after 300 seconds waiting for the image to settle"
        failed.repos = ["alpha/one"]
        let deleting = record(phase: .deleting)

        delegate.rebuildVMSection(status: FleetStatus(records: [busy, failed, deleting]))

        let rows = vmRows()
        XCTAssertEqual(rows.count, 3, "one menu row per record")
        XCTAssertTrue(rows[0].title.contains("kinhin-busy-test") && rows[0].title.contains("busy"))
        XCTAssertTrue(rows[0].title.contains("2 repos"), "multi-repo attribution renders as a count: \(rows[0].title)")
        XCTAssertTrue(rows[0].title.contains("(build)"))
        XCTAssertEqual(rows[1].representedObject as? String, failed.id)
        XCTAssertTrue(rows[1].title.contains("⚠︎"), "errors must be visible in the menu: \(rows[1].title)")
        XCTAssertTrue(rows[1].title.contains("alpha/one"), "single repo renders by name: \(rows[1].title)")
        XCTAssertEqual(rows[2].representedObject as? String, deleting.id)
        XCTAssertTrue(rows[2].title.contains("deleting"))
    }

    func testVMSectionEmptyState() {
        delegate.rebuildVMSection(status: FleetStatus(records: []))
        let rows = vmRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "  (no VMs)")
        XCTAssertEqual(rows[0].isEnabled, false)
    }

    func testVMSectionNilStatusShowsNoVMs() {
        delegate.rebuildVMSection(status: nil)
        XCTAssertEqual(vmRows().map(\.title), ["  (no VMs)"])
    }

    func testVMSectionRebuildIsIdempotent() {
        delegate.rebuildVMSection(status: FleetStatus(records: [record(phase: .ready)]))
        delegate.rebuildVMSection(status: FleetStatus(records: [record(phase: .busy), record(phase: .ready)]))

        let rows = vmRows()
        XCTAssertEqual(rows.count, 2, "stale rows must be cleared, not appended")
        XCTAssertTrue(rows.allSatisfy { $0.title.contains("kinhin-") })

        delegate.rebuildVMSection(status: nil)
        XCTAssertEqual(vmRows().map(\.title), ["  (no VMs)"], "rebuild back to empty")
    }

    func testVMSectionGrowsOnlyInsideTheVMSection() {
        let before = menu.items.count
        delegate.rebuildVMSection(status: FleetStatus(records: (0..<5).map { _ in record(phase: .ready) }))
        XCTAssertEqual(menu.items.count, before + 5, "rows must stay inside the VM section")
        // The pre-existing items keep their order; rows land at the tail.
        XCTAssertEqual(Array(menu.items[..<before]), originalItems)
    }

    // MARK: helpers

    private func record(phase: VMPhase) -> VMRecord {
        var record = VMRecord(id: "kinhin-\(phase.rawValue)-test", phase: phase)
        record.createdAt = Date()
        return record
    }

    /// Menu rows between the "vmSectionStart" header and the end of the menu.
    private func vmRows() -> [NSMenuItem] {
        guard let start = menu.items.firstIndex(where: { $0.identifier?.rawValue == "vmSectionStart" }) else {
            return []
        }
        return Array(menu.items[(start + 1)...])
    }
}
