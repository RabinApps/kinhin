import AppKit
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
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

    // MARK: - App-side failures reach the menu

    private var problemRows: [String] {
        menu.items.filter { $0.identifier?.rawValue == "statusLineExtra" }.map(\.title).filter { $0.hasPrefix("⚠") }
    }

    func testAProblemRendersUnderTheStatusLineAndClears() async {
        var status = FleetStatus()
        status.running = true
        delegate.fleet.status = status
        delegate.fleet.setProblem(.configPush, "config not applied")
        await waitUntil("problem row") { problemRows == ["⚠ config not applied"] }
        delegate.fleet.setProblem(.configPush, nil)
        await waitUntil("row gone") { problemRows.isEmpty }
    }

    func testAutoStartFailureIsShownInTheMenuNotAModal() async {
        var alerted = false
        AlertKit.runModal = { _ in
            alerted = true
            return .alertFirstButtonReturn
        }
        defer { AlertKit.runModal = { $0.runModal() } }
        let fake = FakeFleetServing()
        fake.commandError = RPCError.timeout
        delegate.fleet.service = fake

        await delegate.runAutoStart()

        let problem = delegate.fleet.problems[.launch]
        XCTAssertEqual(
            problem,
            "The fleet didn't start at launch: \(RPCError.timeout.localizedDescription). Start it from the menu or the Fleet tab."
        )
        await waitUntil("menu row") { problemRows == ["⚠ \(problem ?? "")"] }
        XCTAssertFalse(alerted, "nobody pressed anything: no modal at launch")

        // A start that works clears it.
        fake.commandError = nil
        try? await delegate.fleet.perform(.start)
        XCTAssertNil(delegate.fleet.problems[.launch])
    }

    func testCancelledAutoStartIsNotAFailure() async {
        let fake = FakeFleetServing()
        fake.commandError = CancellationError()
        delegate.fleet.service = fake
        await delegate.runAutoStart()
        XCTAssertTrue(delegate.fleet.problems.isEmpty)
    }

    private func launchConfig() throws -> KinhinConfig {
        try ConfigLoader.parse("accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\n")
    }

    func testEngineBuildFailureAtLaunchIsShownInsteadOfOnlyLogged() async throws {
        struct SoftnetMissing: LocalizedError { var errorDescription: String? { "softnet is not installed" } }
        delegate.fleet.environment.makeEngine = { _, _ in throw SoftnetMissing() }

        delegate.installInProcessEngine(config: try launchConfig(), token: "ghp_test")

        XCTAssertNil(delegate.fleet.service)
        XCTAssertFalse(delegate.setupIncomplete, "the config is complete: setup has nothing to ask")
        let problem = delegate.fleet.problems[.launch]
        XCTAssertEqual(
            problem,
            "The fleet engine couldn't be created: softnet is not installed. The fleet can't run until this is fixed and kinhin is reopened."
        )
        await waitUntil("menu row") { problemRows == ["⚠ \(problem ?? "")"] }

        // A later successful build (setup's Start Fleet re-bootstraps) clears it.
        let host = HostResources(logicalCores: 8, memoryGB: 16, freeDiskGB: 100, arm64: true)
        delegate.fleet.environment.makeEngine = { config, _ in
            FleetEngine(
                config: config, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
                host: host)
        }
        delegate.installInProcessEngine(config: try launchConfig(), token: "ghp_test")
        XCTAssertNotNil(delegate.fleet.engine)
        XCTAssertNil(delegate.fleet.problems[.launch])
    }

    func testCancelledEngineBuildIsNotAFailure() throws {
        delegate.fleet.environment.makeEngine = { _, _ in throw CancellationError() }
        delegate.installInProcessEngine(config: try launchConfig(), token: "ghp_test")
        XCTAssertTrue(delegate.fleet.problems.isEmpty)
    }

    func testLaunchConfigLoadSeparatesMissingFromBroken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-launchcfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")

        XCTAssertNil(try AppDelegate.loadLaunchConfig(at: url).get(), "no file yet: nothing configured")

        try "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\n".write(
            to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try AppDelegate.loadLaunchConfig(at: url).get()?.accounts.count, 1)

        try "- just\n- a list\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AppDelegate.loadLaunchConfig(at: url).get(), "a broken file is an error, not \"none\"")
    }
}
