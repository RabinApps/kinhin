import XCTest
import AppKit
@testable import KinhinKit
@testable import kinhin_app

/// Advanced → Routing: the page must load when shown, and Add Route must
/// either work or say why it can't (never silently do nothing).
@MainActor
final class RoutingTests: XCTestCase {
    private var configURL: URL!

    override func setUp() {
        super.setUp()
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-routing-\(UUID().uuidString).yaml")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: configURL)
        super.tearDown()
    }

    private func write(_ yaml: String) { try? yaml.write(to: configURL, atomically: true, encoding: .utf8) }

    private func makeController() -> RuntimesWindowController {
        let controller = RuntimesWindowController(embeddedIn: NSView())
        controller.configURL = configURL
        return controller
    }

    private func waitUntilLoaded(_ controller: RuntimesWindowController) async {
        for _ in 0..<100 where !controller.hasLoadedForTesting {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testSelectingTheRoutingSectionLoadsIt() {
        // Regression: the page stayed empty because nothing reloaded it when
        // it was opened from the Advanced sub-tabs.
        let window = MainTabsWindowController(defaults: UserDefaults(suiteName: "kinhin-routing-\(UUID().uuidString)")!)
        window.showAdvanced(.routing)
        XCTAssertGreaterThanOrEqual(window.runtimesController?.reloadCount ?? 0, 1)
    }

    func testAddRouteExplainsWhenNothingHasLoaded() {
        let controller = makeController() // no config file at all
        var notice: (String, String)?
        controller.presentNotice = { notice = ($0, $1) }
        controller.addRouteClicked()
        XCTAssertEqual(notice?.0, "Routes are still loading", "never a silent no-op")
    }

    func testAddRouteExplainsWhenOnlyTartIsSetUp() async {
        write("repo: \"acme/widgets\"\nlabels: [a]\n")
        let controller = makeController()
        controller.reload()
        await waitUntilLoaded(controller)
        var notice: (String, String)?
        controller.presentNotice = { notice = ($0, $1) }
        var asked = false
        controller.promptForRoute = { _ in asked = true; return nil }
        controller.addRouteClicked()
        XCTAssertEqual(notice?.0, "Nothing to route to yet")
        XCTAssertTrue(notice?.1.contains("Docker or Apple container") ?? false)
        XCTAssertFalse(asked, "no dialog when there is only one runtime")
    }

    func testAddRouteWritesTheRoute() async throws {
        write("""
        repo: "acme/widgets"
        labels: [a]
        docker:
          image: "kinhin-ci-linux"
        """)
        let controller = makeController()
        controller.reload()
        await waitUntilLoaded(controller)
        var edited = 0
        controller.onEdited = { edited += 1 }
        var offered: [RuntimeID] = []
        controller.promptForRoute = { offered = $0; return ("acme/api", .docker) }
        controller.addRouteClicked()
        XCTAssertEqual(offered, [.tart, .docker], "only configured runtimes are offered")
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(yaml.contains("acme/api"), yaml)
        XCTAssertEqual(edited, 1)
    }

    func testCancellingAddRouteChangesNothing() async throws {
        write("repo: \"acme/widgets\"\nlabels: [a]\ndocker:\n  image: \"x\"\n")
        let before = try String(contentsOf: configURL, encoding: .utf8)
        let controller = makeController()
        controller.reload()
        await waitUntilLoaded(controller)
        controller.promptForRoute = { _ in nil }
        controller.addRouteClicked()
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), before)
    }

    func testRouteFormActuallyLaysOutItsFields() {
        // Regression: alert accessory views don't run Auto Layout.
        let form = RuntimesWindowController.makeRouteForm(runtimes: [.tart, .docker])
        XCTAssertGreaterThan(form.pattern.frame.width, 200)
        XCTAssertTrue(form.view.bounds.contains(form.pattern.frame))
        XCTAssertTrue(form.view.bounds.contains(form.popup.frame))
        XCTAssertEqual(form.popup.numberOfItems, 2)
        XCTAssertEqual(form.popup.item(at: 1)?.representedObject as? String, "docker")
    }

    func testRoutableRuntimes() throws {
        let plain = try ConfigLoader.parse("repo: \"a/b\"\nlabels: [x]\n")
        XCTAssertEqual(RuntimesWindowController.routableRuntimes(in: plain), [.tart])
        let both = try ConfigLoader.parse("repo: \"a/b\"\nlabels: [x]\ncontainer:\n  image: i\ndocker:\n  image: i\n")
        XCTAssertEqual(RuntimesWindowController.routableRuntimes(in: both), [.tart, .appleContainer, .docker])
    }
}
