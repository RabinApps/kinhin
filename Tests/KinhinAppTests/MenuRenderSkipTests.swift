import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The menu is re-rendered only when what it shows changed.
@MainActor
final class MenuRenderSkipTests: XCTestCase {
    private var delegate: AppDelegate!
    private var menu: NSMenu!

    override func setUp() async throws {
        try await super.setUp()
        delegate = AppDelegate()
        menu = delegate.buildMenu()
        delegate.menu = menu
    }

    private func vmRowItems() -> [NSMenuItem] {
        guard let start = menu.items.firstIndex(where: { $0.identifier?.rawValue == "vmSectionStart" }),
            let end = menu.items.firstIndex(where: { $0.identifier?.rawValue == "vmSectionEnd" })
        else {
            return []
        }
        return Array(menu.items[(start + 1)..<end])
    }

    func testAnUnchangedStateRendersNothing() {
        var status = FleetStatus(running: true)
        status.records = [VMRecord(id: "kinhin-1", phase: .ready, createdAt: Date())]
        delegate.fleet.status = status
        delegate.renderFleetState()
        let rows = vmRowItems()
        XCTAssertEqual(rows.count, 1)

        // A new but equal status (a poll with no change): the rows are not rebuilt.
        delegate.fleet.status = status
        delegate.renderFleetState()
        XCTAssertTrue(vmRowItems().first === rows.first, "same item instance: no rebuild happened")
    }

    func testAChangeRendersAgain() {
        var status = FleetStatus(running: true)
        status.records = [VMRecord(id: "kinhin-1", phase: .ready, createdAt: Date())]
        delegate.fleet.status = status
        delegate.renderFleetState()
        let before = vmRowItems().first

        status.records[0].phase = .busy
        delegate.fleet.status = status
        delegate.renderFleetState()
        XCTAssertFalse(vmRowItems().first === before)
        XCTAssertTrue(vmRowItems().first?.title.contains("busy") ?? false)
    }

    func testAFreshMenuIsRenderedEvenForTheSameState() {
        delegate.fleet.status = FleetStatus(running: true)
        delegate.renderFleetState()
        let other = delegate.buildMenu()
        delegate.menu = other
        delegate.renderFleetState()
        XCTAssertTrue(other.items.contains { $0.title == "  (no VMs)" }, "the new menu got its rows")
    }

    func testViewStateIsEqualForEqualFleetState() {
        delegate.fleet.status = FleetStatus(running: true)
        let first = delegate.menuViewState()
        delegate.fleet.status = FleetStatus(running: true)
        XCTAssertEqual(delegate.menuViewState(), first)
        delegate.fleet.status = FleetStatus(running: true, paused: true)
        XCTAssertNotEqual(delegate.menuViewState(), first)
    }
}
