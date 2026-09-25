import XCTest

@testable import KinhinKit

/// Budget editing math: slider drags keep weights consistent with the
/// default-remainder rule, and every result round-trips through the
/// validated config editor.
final class BudgetEditorTests: XCTestCase {
    // MARK: - Fixtures

    private let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)
    private let reserve = KinhinConfig.Reserve(cpu: 2, memoryGB: 4)

    // MARK: setShare

    func testSetShareGivesDefaultTheRemainder() {
        let result = BudgetEditor.setShare(
            of: .appleContainer, to: 0.4,
            current: ["tart": 1.0],
            defaultRuntime: .tart
        )
        XCTAssertEqual(result["appleContainer"] ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(result["tart"] ?? 0, 0.6, accuracy: 0.0001)
    }

    func testSetShareScalesOtherNonDefaultRuntimesProportionally() {
        // Three runtimes: docker joins tart and container in the non-default
        // set. Cutting container to 0.2 from 0.5 redistributes the vacated
        // 0.3 across docker/tart(non-default) by share.
        let result = BudgetEditor.setShare(
            of: .appleContainer, to: 0.2,
            current: ["tart": 0.2, "appleContainer": 0.5, "docker": 0.3],
            defaultRuntime: .host
        )
        XCTAssertEqual(result["appleContainer"] ?? 0, 0.2, accuracy: 0.0001)
        // docker: 0.3 + 0.3*(0.3/0.5) = 0.48
        XCTAssertEqual(result["docker"] ?? 0, 0.48, accuracy: 0.0001)
        // tart: 0.2 + 0.3*(0.2/0.5) = 0.32
        XCTAssertEqual(result["tart"] ?? 0, 0.32, accuracy: 0.0001)
        // host (default) gets the remainder: 0
        XCTAssertEqual(result["host"] ?? 0, 0, accuracy: 0.0001)
    }

    func testSetShareToFullLeavesDefaultNothing() {
        let result = BudgetEditor.setShare(
            of: .appleContainer, to: 1.0,
            current: ["tart": 1.0],
            defaultRuntime: .tart
        )
        XCTAssertEqual(result["appleContainer"] ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result["tart"] ?? 0, 0.0, accuracy: 0.0001)
    }

    func testSetShareClampsFloatNoise() {
        let result = BudgetEditor.setShare(
            of: .appleContainer, to: 0.3356721,
            current: ["tart": 0.6643279],
            defaultRuntime: .tart
        )
        XCTAssertEqual(result["appleContainer"] ?? 0, 0.34, accuracy: 0.0001)
        XCTAssertEqual(result["tart"] ?? 0, 0.66, accuracy: 0.0001)
    }

    // MARK: addRuntime

    func testAddRuntimeTakesEvenSliceFromExistingNonDefaults() {
        let result = BudgetEditor.addRuntime(
            .appleContainer,
            current: ["tart": 0.5, "host": 0.5],
            defaultRuntime: .host
        )
        // Non-default budget (0.5) splits evenly: tart 0.25 + newcomer 0.25.
        XCTAssertEqual(result["appleContainer"] ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(result["tart"] ?? 0, 0.25, accuracy: 0.0001)
        // host keeps the remainder.
        XCTAssertEqual(result["host"] ?? 0, 0.5, accuracy: 0.0001)
    }

    func testAddRuntimeIsIdempotent() {
        let current = ["tart": 0.6, "appleContainer": 0.4]
        let result = BudgetEditor.addRuntime(.appleContainer, current: current, defaultRuntime: .tart)
        XCTAssertEqual(result, current)
    }

    // MARK: displayShares

    func testDisplaySharesFillsDefaultRemainder() {
        let shares = BudgetEditor.displayShares(current: ["appleContainer": 0.4], defaultRuntime: .tart)
        XCTAssertEqual(shares["tart"] ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertEqual(shares["appleContainer"] ?? 0, 0.4, accuracy: 0.0001)
    }

    func testDisplaySharesHandlesEmptyBudget() {
        let shares = BudgetEditor.displayShares(current: [:], defaultRuntime: .tart)
        XCTAssertEqual(shares["tart"] ?? 0, 1.0, accuracy: 0.0001)
    }

    // MARK: validate

    func testValidateRejectsOutOfSumAndRange() {
        XCTAssertNil(BudgetEditor.validate(["tart": 0.6, "appleContainer": 0.4]))
        XCTAssertNil(BudgetEditor.validate(["tart": 1.0]))
        XCTAssertNotNil(BudgetEditor.validate(["tart": 0.7, "appleContainer": 0.7]))
        XCTAssertNotNil(BudgetEditor.validate(["tart": 0]))
        XCTAssertNotNil(BudgetEditor.validate(["tart": 1.5]))
    }

    // MARK: starvedRoutes

    func testStarvedRoutesFlagsZeroCapRuntimesWithRoutes() {
        let routes = [
            KinhinConfig.RuntimeConfig.Route(pattern: "acme/api", runtime: "appleContainer"),
            KinhinConfig.RuntimeConfig.Route(pattern: "acme/web", runtime: "tart"),
        ]
        let warnings = BudgetEditor.starvedRoutes(
            routes: routes,
            caps: [.tart: 1, .appleContainer: 0],
            configuredRuntimes: [.tart, .appleContainer]
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("appleContainer has a cap of 0"))
        XCTAssertTrue(warnings[0].contains("1 route"))
    }

    func testStarvedRoutesPluralizesAndDedupes() {
        let routes = [
            KinhinConfig.RuntimeConfig.Route(pattern: "acme/api", runtime: "appleContainer"),
            KinhinConfig.RuntimeConfig.Route(pattern: "acme/web@Nightly", runtime: "appleContainer"),
        ]
        let warnings = BudgetEditor.starvedRoutes(
            routes: routes,
            caps: [.tart: 2, .appleContainer: 0],
            configuredRuntimes: [.tart, .appleContainer]
        )
        XCTAssertEqual(warnings.count, 1, "one warning per starved runtime, not per route")
        XCTAssertTrue(warnings[0].contains("2 routes"))
    }

    func testStarvedRoutesEmptyWhenEveryRouteHasCapacity() {
        let routes = [KinhinConfig.RuntimeConfig.Route(pattern: "acme/api", runtime: "appleContainer")]
        let warnings = BudgetEditor.starvedRoutes(
            routes: routes,
            caps: [.tart: 1, .appleContainer: 3],
            configuredRuntimes: [.tart, .appleContainer]
        )
        XCTAssertTrue(warnings.isEmpty)
    }

    func testStarvedRoutesIgnoresUnconfiguredRuntimes() {
        // A route to an unconfigured runtime is ConfigLoader's problem.
        let routes = [KinhinConfig.RuntimeConfig.Route(pattern: "acme/api", runtime: "docker")]
        let warnings = BudgetEditor.starvedRoutes(
            routes: routes,
            caps: [.tart: 1],
            configuredRuntimes: [.tart]
        )
        XCTAssertTrue(warnings.isEmpty)
    }

    // MARK: previewCaps

    func testPreviewCapsMatchPartitionMath() {
        let caps = BudgetEditor.previewCaps(
            host: host,
            reserve: reserve,
            vmShape: (4, 8),
            containerShape: (2, 4),
            weights: ["tart": 0.6, "appleContainer": 0.4],
            defaultRuntime: .tart
        )
        // usable 10 cpu / 28 GB: container 0.4 → 4cpu/11GB ÷ (2,4) = 2;
        // tart remainder 6cpu/17GB ÷ (4,8) = 1.
        XCTAssertEqual(caps[.appleContainer], 2)
        XCTAssertEqual(caps[.tart], 1)
    }

    func testPreviewCapsAtSliderExtreme() {
        let caps = BudgetEditor.previewCaps(
            host: host,
            reserve: reserve,
            vmShape: (4, 8),
            containerShape: (2, 4),
            weights: ["appleContainer": 1.0],
            defaultRuntime: .tart
        )
        // Everything to containers: 10÷2 = 5 (memory 28÷4 = 7, cpu binds).
        XCTAssertEqual(caps[.appleContainer], 5)
        XCTAssertEqual(caps[.tart], 0)
    }

    func testPreviewCapsEmptyWeightsGivesDefaultEverything() {
        let caps = BudgetEditor.previewCaps(
            host: host,
            reserve: reserve,
            vmShape: (4, 8),
            containerShape: nil,
            weights: [:],
            defaultRuntime: .tart
        )
        // No split: the whole usable budget in VM shape → 10÷4 = 2.
        XCTAssertEqual(caps[.tart], 2)
    }

    // MARK: Round-trip through the validated config editor

    func testBudgetRoundTripThroughConfigEditor() throws {
        let base = """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            container:
              image: "kinhin-ci-linux"
              cpus: 2
              memory_gb: 4
            """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.yaml")
        try base.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Simulate the pane: slider sets container share, editor writes it.
        let budget = BudgetEditor.setShare(of: .appleContainer, to: 0.4, current: ["tart": 1.0], defaultRuntime: .tart)
        let rc = KinhinConfig.RuntimeConfig(defaultRuntime: "tart", budget: budget, routes: [])
        try RuntimesConfigEditor.apply(rc, to: url)

        // Reload: the shares must come back exactly.
        let parsed = try RuntimesConfigEditor.parsed(from: try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(parsed?.budget["appleContainer"] ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(parsed?.budget["tart"] ?? 0, 0.6, accuracy: 0.0001)

        // And the pane's display shares agree.
        let shares = BudgetEditor.displayShares(current: parsed?.budget ?? [:], defaultRuntime: .tart)
        XCTAssertEqual(shares["tart"] ?? 0, 0.6, accuracy: 0.0001)
    }
}
