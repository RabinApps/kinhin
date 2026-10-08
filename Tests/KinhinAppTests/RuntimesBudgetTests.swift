import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The Routing pane's budget slider UX at the model level: a drag updates the
/// live previews on every tick and writes the config only after the drag
/// settles (debounce), the "N inst" previews match the engine's partition
/// math at edge splits, zero shares are written by omission (never an alert),
/// and a split that would starve a route says so before the user lets go.
/// The host snapshot is pinned, so cap assertions are exact.
@MainActor
final class RuntimesBudgetTests: XCTestCase {
    // MARK: - Fixtures

    /// Pinned host: 12 cores, 64 GB; reserve 2/4 → usable 10 CPU / 60 GB.
    private let host = HostResources(logicalCores: 12, memoryGB: 64, freeDiskGB: 200, arm64: true)

    /// Pool shapes: tart (4 CPU, 8 GB) and container (2 CPU, 4 GB).
    private let config = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
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

    override func setUp() async throws {
        try await super.setUp()
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-budget-\(UUID().uuidString).yaml")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configURL)
        try await super.tearDown()
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

    // MARK: - Debounce

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
        model.onChanged = { edited += 1 }
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

    // MARK: - Drag lifecycle, typed shares, locks

    private let threePools = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: ["self-hosted"]
        reserve:
          cpu: 2
          memory_gb: 4
        container:
          image: "kinhin-ci-linux"
          cpus: 2
          memory_gb: 4
        docker:
          image: "kinhin-ci-linux"
        runtimes:
          default: tart
          budget:
            appleContainer: 0.3
            docker: 0.2
        """

    func testHeldDragWritesNothingUntilReleaseThenOnce() async throws {
        var edited = 0
        let model = await loadedModel()
        model.onChanged = { edited += 1 }
        model.budgetDragEditingChanged(true)
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.2)
        try await Task.sleep(nanoseconds: 600_000_000)  // past the debounce: still held
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.5)
        XCTAssertFalse(try String(contentsOf: configURL, encoding: .utf8).contains("budget:"), "nothing mid-drag")
        XCTAssertEqual(model.percentText(for: .appleContainer), "50%")

        model.budgetDragEditingChanged(false)
        let yaml = await waitForDisk("appleContainer: 0.5")
        XCTAssertTrue(yaml.contains("appleContainer: 0.5"), yaml)
        XCTAssertEqual(edited, 1)
    }

    func testDragRescalesFromTheStartingSplitSoItRestoresOnTheWayBack() async throws {
        let model = await loadedModel(threePools)
        model.budgetDragEditingChanged(true)
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.0)
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.3)
        XCTAssertEqual(model.percentShares["appleContainer"] ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(model.percentShares["tart"] ?? 0, 0.5, accuracy: 0.001, "back to the starting split")
        model.budgetDragEditingChanged(false)
    }

    func testReloadWaitsForTheReleaseOfADrag() async throws {
        let model = await loadedModel()
        let loads = model.loads
        model.budgetDragEditingChanged(true)
        model.reload()
        XCTAssertEqual(model.loads, loads, "a reload mid-drag would rebuild rows under the user's hand")
        model.budgetDragEditingChanged(false)
        XCTAssertEqual(model.loads, loads + 1, "deferred reload runs on release")
    }

    func testParsePercentAcceptsNumbersAndRejectsJunk() {
        XCTAssertEqual(RuntimesModel.parsePercent("35"), 35)
        XCTAssertEqual(RuntimesModel.parsePercent(" 35% "), 35)
        XCTAssertEqual(RuntimesModel.parsePercent("7.5"), 7.5)
        XCTAssertNil(RuntimesModel.parsePercent(""))
        XCTAssertNil(RuntimesModel.parsePercent("abc"))
        XCTAssertNil(RuntimesModel.parsePercent("-5"))
        XCTAssertNil(RuntimesModel.parsePercent("nan"))
        XCTAssertNil(RuntimesModel.parsePercent("inf"))
    }

    func testTypedShareCommitsImmediately() async throws {
        let model = await loadedModel()
        model.budgetPercentTyped(runtime: .appleContainer, text: "40%")
        let yaml = await waitForDisk("appleContainer: 0.4")
        XCTAssertTrue(yaml.contains("appleContainer: 0.4"), yaml)
        XCTAssertTrue(yaml.contains("tart: 0.6"), yaml)
        XCTAssertEqual(model.budgetNotice, "")
    }

    func testTypedJunkAndOversizeAreHandled() async throws {
        let model = await loadedModel()
        model.budgetPercentTyped(runtime: .appleContainer, text: "abc")
        XCTAssertFalse(try String(contentsOf: configURL, encoding: .utf8).contains("budget:"), "junk writes nothing")
        model.budgetPercentTyped(runtime: .appleContainer, text: "250")
        let yaml = await waitForDisk("appleContainer: 1")
        XCTAssertTrue(yaml.contains("appleContainer: 1"), "over 100 clamps to 100%: \(yaml)")
    }

    func testLockedPoolCapsTypedShareAndSaysWhy() async throws {
        let model = await loadedModel(threePools)
        model.toggleLock(.tart)
        XCTAssertTrue(model.isLocked(.tart))
        model.budgetPercentTyped(runtime: .appleContainer, text: "90")
        let yaml = await waitForDisk("appleContainer: 0.5")
        XCTAssertTrue(yaml.contains("tart: 0.5"), "locked tart untouched: \(yaml)")
        XCTAssertTrue(yaml.contains("appleContainer: 0.5"), "capped at 1 − tart: \(yaml)")
        XCTAssertEqual(model.budgetNotice, "Capped at 50% — tart is locked.")
    }

    func testLockingLeavesOnlyPoolsWithAnUnlockedNeighbourMovable() async throws {
        let model = await loadedModel(threePools)
        model.toggleLock(.tart)
        XCTAssertTrue(model.canMoveBudget(.appleContainer), "container trades with docker")
        XCTAssertFalse(model.canMoveBudget(.tart), "locked pools don't move")
        model.toggleLock(.docker)
        XCTAssertFalse(model.canMoveBudget(.appleContainer), "every neighbour locked: nothing to trade with")
        model.toggleLock(.docker)
        XCTAssertTrue(model.canMoveBudget(.appleContainer))
    }

    func testTwoPoolFleetWithALockCannotMove() async throws {
        let model = await loadedModel()
        model.toggleLock(.tart)
        XCTAssertFalse(model.canMoveBudget(.appleContainer))
    }

    // MARK: - Cap previews at edge splits

    func testPreviewsAtEdgeSplits() async throws {
        let model = await loadedModel()

        // Everything to containers (weight 1.0): 10 cpu ÷ 2 = 5 (cpu binds;
        // mem 60 ÷ 4 = 15), and the default keeps nothing.
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 1.0)
        XCTAssertEqual(model.capPreviews[.appleContainer], 5)
        XCTAssertEqual(model.capPreviews[.tart], 0, "the default keeps nothing at the extreme")
        XCTAssertEqual(model.percentText(for: .appleContainer), "100%")
        XCTAssertEqual(model.budgetRows.first { $0.id == .tart }?.share, 0)
        XCTAssertEqual(model.budgetRows.first { $0.id == .appleContainer }?.cap, 5)

        // Back to a mid split: each tick recomputes from scratch.
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.4)
        XCTAssertEqual(model.capPreviews[.appleContainer], 2, "4.0 cpu ÷ 2 = 2 (cpu binds; mem 24 ÷ 4 = 6)")
        XCTAssertEqual(model.capPreviews[.tart], 1, "remainder 6 cpu ÷ 4 = 1 (cpu binds; mem 36 ÷ 8 = 4)")
    }

    func testZeroSplitPreviewsZeroCapsForTheDraggedRuntime() async throws {
        let model = await loadedModel()
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.0)
        XCTAssertEqual(model.capPreviews[.tart], 2, "10 cpu ÷ 4 = 2, all to the default")
        XCTAssertEqual(
            model.budgetRows.first { $0.id == .appleContainer }?.cap, 0,
            "no weight, no cap — the omitted key reads as 0 on the row")
        XCTAssertEqual(model.budgetRows.first { $0.id == .tart }?.share, 1.0, "the default absorbs everything")
        XCTAssertEqual(model.budgetRows.first { $0.id == .tart }?.cap, 2)
        XCTAssertEqual(model.percentText(for: .appleContainer), "0%")
    }

    /// The old UI refused an exact-zero split with a modal alert after the
    /// drag settled. Now zero is a legal share: it lands on disk as an
    /// omitted key (ConfigLoader rejects an explicit 0), the default
    /// absorbs the capacity, and nothing interrupts the user.
    func testZeroShareIsWrittenByOmissionWithoutAnAlert() async throws {
        let model = await loadedModel()
        var alerts = 0
        AlertKit.runModal = { _ in
            alerts += 1; return .alertFirstButtonReturn
        }
        defer { AlertKit.runModal = { $0.runModal() } }
        var edited = 0
        model.onChanged = { edited += 1 }

        // Give containers a share first, then take it all back.
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.4)
        let settled = await waitForDisk("appleContainer: 0.4")
        XCTAssertTrue(settled.contains("tart: 0.6"), settled)
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.0)

        let yaml = await waitForDisk("tart: 1")
        XCTAssertFalse(yaml.contains("appleContainer"), "zero share = omitted key: \(yaml)")
        XCTAssertTrue(yaml.contains("tart: 1"), "the default absorbs everything: \(yaml)")
        XCTAssertEqual(alerts, 0, "a legal split never alerts")
        XCTAssertEqual(edited, 2, "one engine reload per settled drag")
        XCTAssertNil(model.starvedRoutes.first, "no routes in the fixture — nothing starved")
    }

    /// The old UI refused an exact-100% split too (setShare stored the
    /// default at an explicit 0, which validate rejects). Omission fixes
    /// the extreme end of every slider.
    func testFullShareCommitsInsteadOfAlerting() async throws {
        let model = await loadedModel()
        var alerts = 0
        AlertKit.runModal = { _ in
            alerts += 1; return .alertFirstButtonReturn
        }
        defer { AlertKit.runModal = { $0.runModal() } }
        var edited = 0
        model.onChanged = { edited += 1 }

        model.budgetSliderChanged(runtime: .appleContainer, fraction: 1.0)
        let yaml = await waitForDisk("appleContainer: 1")
        XCTAssertFalse(yaml.contains("tart:"), "the default is at zero — omitted: \(yaml)")
        XCTAssertEqual(alerts, 0)
        XCTAssertEqual(edited, 1)
    }

    /// The default pool has a slider like everyone else's: dragging it
    /// rescales the other pools so the shares still total 100%.
    func testDraggingTheDefaultRescalesTheOtherPools() async throws {
        let model = await loadedModel()
        model.budgetSliderChanged(runtime: .tart, fraction: 0.3)
        XCTAssertEqual(model.percentText(for: .tart), "30%")
        XCTAssertEqual(model.percentText(for: .appleContainer), "70%")

        let yaml = await waitForDisk("tart: 0.3")
        XCTAssertTrue(yaml.contains("appleContainer: 0.7"), yaml)
    }

    // MARK: - Percent labels

    func testPercentTextPrefersTheLiveTickOverTheDiskShare() async throws {
        let model = await loadedModel()
        model.budgetSliderChanged(runtime: .appleContainer, fraction: 0.3)
        XCTAssertEqual(model.percentText(for: .appleContainer), "30%")
        XCTAssertEqual(model.percentText(for: .tart), "70%", "the default's percent is the live remainder")
    }

    // MARK: - Starved-route warning

    func testStarvedRouteWarningTextNamesTheRuntimeAndRouteCount() async throws {
        let routed = """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
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
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
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
