import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The delegate's one render path: controller state in, menu items out.
@MainActor
final class AppDelegateRenderingTests: XCTestCase {
    private var delegate: AppDelegate!
    private var menu: NSMenu!

    override func setUp() async throws {
        try await super.setUp()
        delegate = AppDelegate()
        menu = delegate.buildMenu()
        delegate.menu = menu
        delegate.observeControllers()
    }

    private func item(_ id: String) -> NSMenuItem? { menu.items.first { $0.identifier?.rawValue == id } }

    private func waitUntil(_ message: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out: \(message)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A menu item title is one line, so a multi-line status becomes one disabled row per line.
    func testMultiLineStatusRendersOneRowPerLine() {
        delegate.renderStatusLines("Running — queue 0\n  ⏱ queue age: 6s old\n  ⚠ forge API budget is low")
        let first = try? XCTUnwrap(item("statusLine"))
        XCTAssertEqual(first?.title, "Running — queue 0")
        let extras = menu.items.filter { $0.identifier?.rawValue == "statusLineExtra" }
        XCTAssertEqual(extras.map(\.title), ["⏱ queue age: 6s old", "⚠ forge API budget is low"])
        XCTAssertTrue(extras.allSatisfy { !$0.isEnabled })
        let index = menu.items.firstIndex { $0.identifier?.rawValue == "statusLine" } ?? -1
        XCTAssertEqual(menu.items[index + 1].identifier?.rawValue, "statusLineExtra", "rows sit right below the status")

        // Rendering again replaces the rows instead of piling up.
        delegate.renderStatusLines("Stopped — queue 0")
        XCTAssertTrue(menu.items.filter { $0.identifier?.rawValue == "statusLineExtra" }.isEmpty)
        XCTAssertEqual(item("statusLine")?.title, "Stopped — queue 0")
    }

    func testStatusChangesReRenderTheMenuAndKeepObserving() async {
        var status = FleetStatus()
        status.running = true
        delegate.fleet.status = status
        await waitUntil("first render") { item("statusLine")?.title.hasPrefix("Running") == true }
        XCTAssertEqual(item("stopFleet")?.isHidden, false)
        XCTAssertEqual(item("startFleet")?.isHidden, true)

        // The observer must re-arm itself after each change.
        status.running = false
        delegate.fleet.status = status
        await waitUntil("second render") { item("statusLine")?.title.hasPrefix("Stopped") == true }
        XCTAssertEqual(item("startFleet")?.isHidden, false)
    }

    func testPendingActionReRendersTheStatusLine() async {
        delegate.fleet.pendingFleetAction = .start
        await waitUntil("starting") { item("statusLine")?.title == "Starting…" }
        delegate.fleet.pendingFleetAction = nil
        await waitUntil("normal again") { item("statusLine")?.title != "Starting…" }
    }

    func testUnreachableFleetIsNotShownAsNeedingSetup() async {
        let fake = FakeFleetServing()
        fake.statusError = RPCError.timeout
        delegate.fleet.service = fake
        await delegate.fleet.refresh()
        await waitUntil("not responding") { item("statusLine")?.title.hasPrefix("Fleet not responding") == true }
    }

    func testUpdateStateReRendersTheUpdateItems() async {
        let info = UpdateInfo(
            tag: "v9.9.9", version: "9.9.9", dmgName: "kinhin-9.9.9-arm64.dmg",
            dmgURL: URL(string: "https://example.com/d.dmg")!, releaseURL: URL(string: "https://example.com/r")!,
            publishedAt: nil, notes: nil)
        delegate.updates.pendingUpdate = info
        await waitUntil("offered") { item("updateItem")?.isHidden == false }
        delegate.updates.updateCardState = .downloading(name: info.dmgName)
        await waitUntil("downloading") { item("updateItem")?.title.hasPrefix("Downloading") == true }
        delegate.updates.pendingUpdate = nil
        delegate.updates.updateCardState = .upToDate(lastChecked: nil)
        await waitUntil("hidden") { item("updateItem")?.isHidden == true }
    }

    func testObservationSurvivesAMissingMenu() async {
        delegate.menu = nil  // menu-bar-less launch mode
        delegate.fleet.pendingFleetAction = .stop
        try? await Task.sleep(for: .milliseconds(50))
        delegate.menu = menu  // the status item is installed later
        delegate.fleet.pendingFleetAction = nil
        delegate.fleet.pendingFleetAction = .start
        await waitUntil("renders once the menu exists") { item("statusLine")?.title == "Starting…" }
    }
}
