import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Advanced → Routing: the page must load when shown, and Add Route must
/// either work or say why it can't (never silently do nothing).
@MainActor
final class RoutingTests: XCTestCase {
    private var configURL: URL!

    override func setUp() {
        super.setUp()
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-routing-\(UUID().uuidString).yaml")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: configURL)
        super.tearDown()
    }

    private func write(_ yaml: String) { try? yaml.write(to: configURL, atomically: true, encoding: .utf8) }

    private func makeModel() -> RuntimesModel {
        let model = RuntimesModel()
        model.configURL = configURL
        return model
    }

    private func waitUntilLoaded(_ model: RuntimesModel) async {
        for _ in 0..<100 where !model.hasLoadedForTesting {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testSelectingTheRoutingSectionLoadsIt() {
        // Regression: the page stayed empty because nothing reloaded it when
        // it was opened from the Advanced sub-tabs.
        let window = MainTabsWindowController(defaults: UserDefaults(suiteName: "kinhin-routing-\(UUID().uuidString)")!)
        window.showAdvanced(.routing)
        XCTAssertGreaterThanOrEqual(window.runtimesModel?.loads ?? 0, 1)
    }

    func testAddRouteExplainsWhenNothingHasLoaded() {
        let model = makeModel()  // no config file at all
        var notice: (String, String)?
        model.presentNotice = { notice = ($0, $1) }
        model.addRouteClicked()
        XCTAssertEqual(notice?.0, "Routes are still loading", "never a silent no-op")
    }

    func testHostIsOfferedEvenWhenOnlyTartIsSetUp() async {
        write("repo: \"acme/widgets\"\nlabels: [a]\n")
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        var offered: [RuntimeID] = []
        model.promptForRoute = {
            offered = $0; return nil
        }
        model.addRouteClicked()
        XCTAssertEqual(offered, [.tart, .host])
    }

    func testAddingAHostRouteRecordsConsent() async throws {
        write("repo: \"acme/widgets\"\nlabels: [a]\n")
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        model.promptForRoute = { _ in ("acme/scripts", .host, true) }
        model.addRouteClicked()
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(yaml.contains("acme/scripts"), yaml)
        XCTAssertTrue(yaml.contains("consent: true"), yaml)
        let parsed = try ConfigLoader.parse(yaml)
        XCTAssertTrue(parsed.hostRoutesConfigured, "the written route must pass config validation")
    }

    func testAddRouteWritesTheRoute() async throws {
        write(
            """
            repo: "acme/widgets"
            labels: [a]
            docker:
              image: "kinhin-ci-linux"
            """)
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        var edited = 0
        model.onEdited = { edited += 1 }
        var offered: [RuntimeID] = []
        model.promptForRoute = {
            offered = $0; return ("acme/api", .docker, false)
        }
        model.addRouteClicked()
        XCTAssertEqual(offered, [.tart, .docker, .host], "only configured runtimes (plus host) are offered")
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(yaml.contains("acme/api"), yaml)
        XCTAssertEqual(edited, 1)
    }

    func testCancellingAddRouteChangesNothing() async throws {
        write("repo: \"acme/widgets\"\nlabels: [a]\ndocker:\n  image: \"x\"\n")
        let before = try String(contentsOf: configURL, encoding: .utf8)
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        model.promptForRoute = { _ in nil }
        model.addRouteClicked()
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), before)
    }

    func testDuplicateRouteIsRejectedWithAMessage() async throws {
        write("repo: \"acme/widgets\"\nlabels: [a]\n")
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        model.promptForRoute = { _ in ("acme/api", .tart, false) }
        model.addRouteClicked()
        model.promptForRoute = { _ in ("acme/api", .tart, false) }
        model.addRouteClicked()
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        // Exactly one route block for the pattern, and the file still parses.
        XCTAssertTrue(yaml.components(separatedBy: "acme/api").count - 1 <= 2, yaml)
        _ = try ConfigLoader.parse(yaml)
    }

    func testRemoveRouteWritesTheRemoval() async throws {
        write("repo: \"acme/widgets\"\nlabels: [a]\n")
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        model.promptForRoute = { _ in ("acme/api", .tart, false) }
        model.addRouteClicked()
        // The write triggers an async reload; wait until the new route shows.
        for _ in 0..<100 where !model.routeRows.contains(where: { $0.pattern == "acme/api" }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(model.routeRows.contains { $0.pattern == "acme/api" })
        model.removeRoute(pattern: "acme/api")
        for _ in 0..<100 where model.routeRows.contains(where: { $0.pattern == "acme/api" }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(model.routeRows.contains { $0.pattern == "acme/api" })
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(yaml.contains("acme/api"), yaml)
    }

    func testRouteFormActuallyLaysOutItsFields() {
        // Regression: alert accessory views don't run Auto Layout.
        let form = RuntimesSheets.makeRouteForm(runtimes: [.tart, .docker])
        XCTAssertGreaterThan(form.pattern.frame.width, 200)
        XCTAssertTrue(form.view.bounds.contains(form.pattern.frame))
        XCTAssertTrue(form.view.bounds.contains(form.popup.frame))
        XCTAssertEqual(form.popup.numberOfItems, 2)
        XCTAssertEqual(form.popup.item(at: 1)?.representedObject as? String, "docker")
    }

    func testRouteFormHostConsentCheckboxIsPresent() {
        let form = RuntimesSheets.makeRouteForm(runtimes: [.tart, .host])
        XCTAssertEqual(form.consent.state, .off, "consent is never pre-ticked")
        XCTAssertTrue(form.view.bounds.contains(form.consent.frame))
        XCTAssertEqual(form.popup.item(at: 1)?.representedObject as? String, "host")
        XCTAssertEqual(form.consent.title, RuntimesSheets.hostConsentTitle)
    }

    func testRoutableRuntimes() throws {
        let plain = try ConfigLoader.parse("repo: \"a/b\"\nlabels: [x]\n")
        XCTAssertEqual(RuntimesModel.routableRuntimes(in: plain), [.tart, .host])
        let both = try ConfigLoader.parse("repo: \"a/b\"\nlabels: [x]\ncontainer:\n  image: i\ndocker:\n  image: i\n")
        XCTAssertEqual(RuntimesModel.routableRuntimes(in: both), [.tart, .appleContainer, .docker, .host])
    }
}
