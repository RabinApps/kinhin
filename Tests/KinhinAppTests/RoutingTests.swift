import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Advanced → Routing: the page must load when shown, and Add Route must
/// either work or say why it can't (never silently do nothing). The sheet is
/// driven through `RuntimesModel`'s state and actions, so no test opens real UI.
@MainActor
final class RoutingTests: XCTestCase {
    private var configURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-routing-\(UUID().uuidString).yaml")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configURL)
        try await super.tearDown()
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
        let window = MainTabsWindowController(
            defaults: UserDefaults(suiteName: "kinhin-routing-\(UUID().uuidString)")!, fleet: FleetController(),
            updates: UpdateController())
        window.tabs.showAdvanced(.routing)
        XCTAssertGreaterThanOrEqual(window.models.runtimesModel?.loads ?? 0, 1)
    }

    func testAddRouteExplainsWhenNothingHasLoaded() {
        let model = makeModel()  // no config file at all
        var notice: (String, String)?
        model.presentNotice = { notice = ($0, $1) }
        model.addRouteClicked()
        XCTAssertEqual(notice?.0, "Routes are still loading", "never a silent no-op")
        XCTAssertNil(model.routeOffer)
    }

    func testHostIsOfferedEvenWhenOnlyTartIsSetUp() async {
        write("accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [a]\n")
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        model.addRouteClicked()
        XCTAssertEqual(model.routeOffer?.runtimes, [.tart, .host])
    }

    func testAddingAHostRouteRecordsConsent() async throws {
        write("accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [a]\n")
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        model.addRouteClicked()
        model.confirmAddRoute(rawPattern: "acme/scripts", runtime: .host, consent: true)
        XCTAssertNil(model.routeOffer, "the sheet closes after a successful write")
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(yaml.contains("acme/scripts"), yaml)
        XCTAssertTrue(yaml.contains("consent: true"), yaml)
        let parsed = try ConfigLoader.parse(yaml)
        XCTAssertTrue(parsed.hostRoutesConfigured, "the written route must pass config validation")
    }

    func testAddRouteWritesTheRoute() async throws {
        write(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: [a]
            docker:
              image: "kinhin-ci-linux"
            """)
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        var edited = 0
        model.onChanged = { edited += 1 }
        model.addRouteClicked()
        XCTAssertEqual(
            model.routeOffer?.runtimes, [.tart, .docker, .host],
            "only configured runtimes (plus host) are offered")
        model.confirmAddRoute(rawPattern: "acme/api", runtime: .docker, consent: false)
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(yaml.contains("acme/api"), yaml)
        XCTAssertEqual(edited, 1)
    }

    func testCancellingAddRouteChangesNothing() async throws {
        write(
            "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [a]\ndocker:\n  image: \"x\"\n"
        )
        let before = try String(contentsOf: configURL, encoding: .utf8)
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        model.addRouteClicked()
        model.cancelAddRoute()
        XCTAssertNil(model.routeOffer)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), before)
    }

    func testDuplicateRouteIsRejectedInsideTheSheet() async throws {
        write("accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [a]\n")
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        model.addRouteClicked()
        model.confirmAddRoute(rawPattern: "acme/api", runtime: .tart, consent: false)
        // The write triggers an async reload; wait for it so the sheet's
        // second attempt sees the route already on disk.
        for _ in 0..<100 where !model.routeRows.contains(where: { $0.pattern == "acme/api" }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        model.addRouteClicked()  // reopen; the first route is now on disk
        model.confirmAddRoute(rawPattern: "acme/api", runtime: .tart, consent: false)
        XCTAssertEqual(model.sheetProblem, "A route for 'acme/api' already exists.")
        XCTAssertNotNil(model.routeOffer, "the sheet stays open so the pattern can be fixed")
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        // Exactly one route block for the pattern, and the file still parses.
        XCTAssertTrue(yaml.components(separatedBy: "acme/api").count - 1 <= 2, yaml)
        _ = try ConfigLoader.parse(yaml)
    }

    func testEmptyPatternIsRejectedInsideTheSheet() async throws {
        write("accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [a]\n")
        let before = try String(contentsOf: configURL, encoding: .utf8)
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        model.addRouteClicked()
        model.confirmAddRoute(rawPattern: "   ", runtime: .tart, consent: false)
        XCTAssertEqual(model.sheetProblem, "Enter a repository (owner/repo) first.")
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), before)
    }

    func testHostRouteNeedsConsentInsideTheSheet() async throws {
        write("accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [a]\n")
        let before = try String(contentsOf: configURL, encoding: .utf8)
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        model.addRouteClicked()
        model.confirmAddRoute(rawPattern: "acme/api", runtime: .host, consent: false)
        XCTAssertTrue(model.sheetProblem.contains("Tick the box"), model.sheetProblem)
        XCTAssertNotNil(model.routeOffer)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), before)
    }

    /// The sheet's verdict order (empty → duplicate → consent) and its
    /// trimming rule, pinned without any UI.
    func testPatternProblemVerdicts() {
        let existing = [KinhinConfig.RuntimeConfig.Route(pattern: "acme/api", runtime: .tart, consent: nil)]
        XCTAssertEqual(
            RuntimesModel.patternProblem("", existing: existing, runtime: .tart, consent: false),
            "Enter a repository (owner/repo) first.")
        XCTAssertEqual(
            RuntimesModel.patternProblem("acme/api", existing: existing, runtime: .tart, consent: false),
            "A route for 'acme/api' already exists.")
        XCTAssertTrue(
            RuntimesModel.patternProblem("acme/new", existing: existing, runtime: .host, consent: false)?
                .contains("Tick the box") ?? false)
        XCTAssertNil(RuntimesModel.patternProblem("acme/new", existing: existing, runtime: .tart, consent: false))
        XCTAssertNil(RuntimesModel.patternProblem("acme/new", existing: existing, runtime: .host, consent: true))
        XCTAssertNil(
            RuntimesModel.patternProblem("  acme/new  ", existing: existing, runtime: .tart, consent: false),
            "surrounding whitespace is trimmed, not rejected")
    }

    func testRemoveRouteWritesTheRemoval() async throws {
        write("accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [a]\n")
        let model = makeModel()
        model.reload()
        await waitUntilLoaded(model)
        model.addRouteClicked()
        model.confirmAddRoute(rawPattern: "acme/api", runtime: .tart, consent: false)
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

    /// The sheet's form contract: consent checkbox only for host routes,
    /// never pre-ticked, and the field labels the pane advertises. Read from
    /// initial state — the struct is a value; SwiftUI owns live copies.
    func testAddRouteSheetForm() {
        let host = AddRouteSheet(model: makeModel(), runtimes: [.tart, .host])
        XCTAssertTrue(AddRouteSheet.consentNeeded(for: .host), "a host choice offers the consent checkbox")
        XCTAssertFalse(AddRouteSheet.consentNeeded(for: .tart), "no consent checkbox without a host choice")
        XCTAssertFalse(host.consentIsOn, "consent is never pre-ticked")
        XCTAssertEqual(AddRouteSheet.patternPlaceholder, "acme/api  or  acme/api@Workflow Name")
        XCTAssertEqual(
            host.runtimeOptions, [RuntimesModel.runtimeTitle(.tart), RuntimesModel.runtimeTitle(.host)])
    }

    func testRoutableRuntimes() throws {
        let plain = try ConfigLoader.parse(
            "accounts:\n  - name: github\n    forge: github\n    scope: \"a/b\"\nlabels: [x]\n")
        XCTAssertEqual(RuntimesModel.routableRuntimes(in: plain), [.tart, .host])
        let both = try ConfigLoader.parse(
            "accounts:\n  - name: github\n    forge: github\n    scope: \"a/b\"\nlabels: [x]\ncontainer:\n  image: i\ndocker:\n  image: i\n"
        )
        XCTAssertEqual(RuntimesModel.routableRuntimes(in: both), [.tart, .appleContainer, .docker, .host])
    }
}
