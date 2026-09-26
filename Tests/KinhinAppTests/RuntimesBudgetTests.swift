import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Routing pane's budget slider UX at the model level: a drag updates the
/// live previews on every tick and writes the config only after the drag
/// settles (debounce), the "N inst" previews match the engine's partition
/// math at edge splits, and a split that would starve a route says so before
/// the user lets go. The host snapshot is pinned, so cap assertions are exact.
@MainActor
final class RuntimesBudgetTests: XCTestCase {
    // MARK: Fixtures

    /// Pinned host: 12 cores, 64 GB; reserve 2/4 → usable 10 CPU / 60 GB.
    private let host = HostResources(logicalCores: 12, memoryGB: 64, freeDiskGB: 200, arm64: true)

    /// Pool shapes: tart (4 CPU, 8 GB) and container (2 CPU, 4 GB).
    private let config = """
        repo: "acme/widgets"
        labels: ["self-hosted"]
        reserve:
          cpu: 2
          memory_gb: 4
        container:
          image: "kinhin-ci-linux"
          cpus: 2
          memory_gb: 4
        runtimes:
          default: tart
        """

    private var configURL: URL!

    override func setUp() {
        super.setUp()
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-budget-\(UUID().uuidString).yaml")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: configURL)
        super.tearDown()
    }

    private func makeModel() -> RuntimesModel {
        let model = RuntimesModel()
        model.configURL = configURL
        model.hostSnapshot = { [host] in host }
        return model
    }

    /// Writes the fixture (or an override), then waits out both passes of
    /// the two-pass reload (`isProbingHealth` clears only after the health
    /// pass has applied the final previews), so later slider ticks are never
    /// clobbered.
    private func loadedModel(_ yaml: String? = nil) async -> RuntimesModel {
        try? (yaml ?? config).write(to: configURL, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.reload()
        for _ in 0..<200 where !model.hasLoadedForTesting || model.isProbingHealth {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return model
    }

    /// Waits until the file contains `needle` (the debounced write landing).
    private func waitForDisk(_ needle: String) async -> String {
        for _ in 0..<200 {
            if let yaml = try? String(contentsOf: configURL, encoding: .utf8), yaml.contains(needle) {
                return yaml
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    }

    // MARK: Debounce

    func testSliderTickUpdatesPreviewsImmediatelyButWritesNothing() async throws {
        let model = await loadedModel()
        let before = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(before.contains("budget:"), "fixture starts without a budget section")

        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.4)
        XCTAssertEqual(model.percentText(for: .appleContainer), "40%", "the tick previews immediately")

        try await Task.sleep(nanoseconds: 100_000_000)  // well inside the 400ms window
        let yaml = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(yaml.contains("budget:"), "a mid-drag tick must not write the config")
    }

    func testDebouncedWriteLandsAfterTheDragSettles() async throws {
        var edited = 0
        let model = await loadedModel()
        model.onEdited = { edited += 1 }
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.4)

        let yaml = await waitForDisk("appleContainer: 0.4")
        XCTAssertTrue(yaml.contains("appleContainer: 0.4"), yaml)
        XCTAssertTrue(yaml.contains("tart: 0.6"), "the default keeps the remainder: \(yaml)")
        XCTAssertEqual(edited, 1, "one engine reload for the whole settled drag")
    }

    func testRapidReticksCancelThePendingWrite() async throws {
        let model = await loadedModel()
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.2)
        try? await Task.sleep(nanoseconds: 200_000_000)  // inside the debounce window
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.5)

        let yaml = await waitForDisk("appleContainer: 0.5")
        XCTAssertFalse(yaml.contains("appleContainer: 0.2"), "the stale pending write must be cancelled: \(yaml)")
    }

    // MARK: Cap previews at edge splits

    func testPreviewsAtEdgeSplits() async throws {
        let model = await loadedModel()

        // Everything to containers (weight 1.0): 10 cpu ÷ 2 = 5 (cpu binds;
        // mem 60 ÷ 4 = 15), and the default keeps nothing.
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 1.0)
        XCTAssertEqual(model.capPreviews[.appleContainer], 5)
        XCTAssertEqual(model.capPreviews[.tart], 0, "the default keeps nothing at the extreme")
        XCTAssertEqual(model.percentText(for: .appleContainer), "100%")
        XCTAssertEqual(model.remainderNote, "tart keeps the remaining 0% — 0 inst")

        // Back to a mid split: each tick recomputes from scratch.
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.4)
        XCTAssertEqual(model.capPreviews[.appleContainer], 2, "4.0 cpu ÷ 2 = 2 (cpu binds; mem 24 ÷ 4 = 6)")
        XCTAssertEqual(model.capPreviews[.tart], 1, "remainder 6 cpu ÷ 4 = 1 (cpu binds; mem 36 ÷ 8 = 4)")
    }

    func testZeroSplitPreviewsZeroCapsForTheDraggedRuntime() async throws {
        let model = await loadedModel()
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.0)
        XCTAssertEqual(model.capPreviews[.appleContainer], 0, "no weight, no cap")
        XCTAssertEqual(model.capPreviews[.tart], 2, "10 cpu ÷ 4 = 2, all to the default")
        XCTAssertEqual(model.remainderNote, "tart keeps the remaining 100% — 2 inst")
        XCTAssertEqual(model.percentText(for: .appleContainer), "0%")
    }

    func testZeroSplitCommitIsRefusedAndSnapsBackWithAnAlert() async throws {
        let model = await loadedModel()
        var alerts = 0
        AlertKit.runModal = { _ in
            alerts += 1; return .alertFirstButtonReturn
        }
        defer { AlertKit.runModal = { $0.runModal() } }
        var edited = 0
        model.onEdited = { edited += 1 }

        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.0)
        try? await Task.sleep(nanoseconds: 600_000_000)  // debounce fires with weight 0

        XCTAssertEqual(alerts, 1, "the exact-zero split must be named, not silently dropped")
        XCTAssertEqual(edited, 0, "a rejected split never fires onEdited")
        XCTAssertEqual(model.budgetShare(for: .appleContainer), 0, "snap back to the on-disk truth: no budget")
        XCTAssertEqual(model.percentText(for: .appleContainer), "0%")
        XCTAssertEqual(model.capPreviews[.tart], 2, "previews reflect the on-disk truth after the snap")
    }

    // MARK: Percent labels

    func testPercentTextPrefersTheLiveTickOverTheDiskShare() async throws {
        let model = await loadedModel()
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.3)
        XCTAssertEqual(model.percentText(for: .appleContainer), "30%")
        XCTAssertEqual(model.percentText(for: .tart), "70%", "the default's percent is the live remainder")
    }

    // MARK: Starved-route warning

    func testStarvedRouteWarningTextNamesTheRuntimeAndRouteCount() async throws {
        let routed = """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            reserve:
              cpu: 2
              memory_gb: 4
            container:
              image: "kinhin-ci-linux"
              cpus: 2
              memory_gb: 4
            runtimes:
              default: tart
              routes:
                - pattern: "acme/api"
                  runtime: appleContainer
                - pattern: "acme/web@Nightly"
                  runtime: appleContainer
            """
        let model = await loadedModel(routed)
        XCTAssertTrue(model.starvedRoutes.isEmpty, "healthy split: nothing starved")

        // Drag containers to zero: both routes to appleContainer strand.
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.0)
        XCTAssertEqual(model.starvedRoutes.count, 1, "one warning per starved runtime, not per route")
        XCTAssertTrue(model.starvedRoutes[0].contains("appleContainer has a cap of 0"), model.starvedRoutes[0])
        XCTAssertTrue(model.starvedRoutes[0].contains("2 routes"), model.starvedRoutes[0])
    }

    func testHostRouteIsNotStarvedByThePartition() async throws {
        // Host runners draw no VM/container budget ("cap n/a" in the pane),
        // so no split can strand a host route.
        let hostRouted = """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            reserve:
              cpu: 2
              memory_gb: 4
            container:
              image: "kinhin-ci-linux"
              cpus: 2
              memory_gb: 4
            runtimes:
              default: tart
              routes:
                - pattern: "acme/scripts"
                  runtime: host
                  consent: true
            """
        let model = await loadedModel(hostRouted)
        XCTAssertTrue(
            model.starvedRoutes.isEmpty,
            "a host route is never starved by a VM/container split: \(model.starvedRoutes)")

        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.0)
        XCTAssertTrue(
            model.starvedRoutes.isEmpty,
            "not even the zero split strands the host route: \(model.starvedRoutes)")
    }
}
