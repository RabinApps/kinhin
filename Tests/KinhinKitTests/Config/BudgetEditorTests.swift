import XCTest

@testable import KinhinKit

/// Budget editing math: slider drags redistribute proportionally so the
/// shares always total 1, zero is spelled by key omission (ConfigLoader
/// rejects an explicit 0), and every result round-trips through the
/// validated config editor.
final class BudgetEditorTests: XCTestCase {
    // MARK: - Fixtures

    private let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)
    private let reserve = KinhinConfig.Reserve(cpu: 2, memoryGB: 4, diskGB: 10)

    // MARK: - setShare

    // MARK: - Locks

    private let three: [String: Double] = ["tart": 0.5, "docker": 0.3, "appleContainer": 0.2]

    func testLockedPoolKeepsItsShareWhileTheOtherAbsorbs() {
        let result = BudgetEditor.setShare(
            of: .docker, to: 0.4, current: three, defaultRuntime: .tart, locked: [.tart])
        XCTAssertEqual(result["tart"] ?? 0, 0.5, accuracy: 0.0001, "locked default untouched")
        XCTAssertEqual(result["docker"] ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(result["appleContainer"] ?? 0, 0.1, accuracy: 0.0001, "the only free pool absorbs")
    }

    func testLockedNonDefaultKeepsItsShare() {
        let result = BudgetEditor.setShare(
            of: .appleContainer, to: 0.4, current: three, defaultRuntime: .tart, locked: [.docker])
        XCTAssertEqual(result["docker"] ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(result["appleContainer"] ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(result["tart"] ?? 0, 0.3, accuracy: 0.0001)
    }

    func testDragIsCappedAtWhatTheUnlockedPoolsCanGive() {
        let result = BudgetEditor.setShare(
            of: .docker, to: 1.0, current: three, defaultRuntime: .tart, locked: [.tart])
        XCTAssertEqual(result["docker"] ?? 0, 0.5, accuracy: 0.0001, "1 − locked tart")
        XCTAssertNil(result["appleContainer"], "the free pool bottoms out at 0 (omitted)")
        XCTAssertEqual(
            BudgetEditor.maxShare(for: .docker, locked: [.tart], current: three, defaultRuntime: .tart), 0.5,
            accuracy: 0.0001)
    }

    func testEveryOtherPoolLockedMakesTheDragANoOp() {
        let result = BudgetEditor.setShare(
            of: .docker, to: 0.9, current: three, defaultRuntime: .tart, locked: [.tart, .appleContainer])
        XCTAssertEqual(result["docker"] ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertFalse(
            BudgetEditor.canMove(
                runtime: .docker, locked: [.tart, .appleContainer], pools: [.tart, .docker, .appleContainer]))
        XCTAssertFalse(
            BudgetEditor.canMove(runtime: .tart, locked: [.tart], pools: [.tart, .docker]), "a locked pool can't move")
        XCTAssertTrue(
            BudgetEditor.canMove(runtime: .docker, locked: [.tart], pools: [.tart, .docker, .appleContainer]))
    }

    func testDraggingALockedPoolChangesNothing() {
        let result = BudgetEditor.setShare(
            of: .docker, to: 0.1, current: three, defaultRuntime: .tart, locked: [.docker])
        XCTAssertEqual(result["docker"] ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(result["tart"] ?? 0, 0.5, accuracy: 0.0001)
    }

    func testShrinkingWhenFreePoolsAreAtZeroSplitsEvenly() {
        let current: [String: Double] = ["tart": 0.4, "docker": 0.6]
        let result = BudgetEditor.setShare(
            of: .docker, to: 0.2, current: current, defaultRuntime: .tart, locked: [.appleContainer])
        XCTAssertEqual(result["docker"] ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(result["tart"] ?? 0, 0.8, accuracy: 0.0001)
    }

    func testLockedDefaultAbsorbsNoRoundingDrift() {
        let current: [String: Double] = ["tart": 0.34, "docker": 0.33, "appleContainer": 0.33]
        let result = BudgetEditor.setShare(
            of: .docker, to: 0.5, current: current, defaultRuntime: .tart, locked: [.tart])
        XCTAssertEqual(result["tart"] ?? 0, 0.34, accuracy: 0.000_001)
        XCTAssertEqual(result.values.reduce(0, +), 1.0, accuracy: 0.0001)
    }

    func testLockedSweepAlwaysTotalsOneAndNeverMovesLockedPools() {
        let pools: [RuntimeID] = [.tart, .docker, .appleContainer]
        let lockSets: [Set<RuntimeID>] = [[], [.tart], [.docker], [.appleContainer], [.tart, .docker]]
        for locked in lockSets {
            for dragged in pools where !locked.contains(dragged) {
                for step in 0...20 {
                    let result = BudgetEditor.setShare(
                        of: dragged, to: Double(step) / 20, current: three, defaultRuntime: .tart, locked: locked)
                    let shares = BudgetEditor.displayShares(current: result, defaultRuntime: .tart)
                    XCTAssertEqual(shares.values.reduce(0, +), 1.0, accuracy: 0.011, "\(locked) \(dragged) \(step)")
                    XCTAssertNil(BudgetEditor.validate(result), "\(locked) \(dragged) \(step)")
                    for pool in locked {
                        XCTAssertEqual(
                            shares[pool.rawValue] ?? 0, three[pool.rawValue] ?? 0, accuracy: 0.000_001,
                            "\(pool) moved while locked: \(locked) dragging \(dragged) to \(step)/20")
                    }
                }
            }
        }
    }

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
        // set. Cutting container to 0.2 from 0.5 rescales the rest — ratios
        // preserved — so the shares still total 1.
        let result = BudgetEditor.setShare(
            of: .appleContainer, to: 0.2,
            current: ["tart": 0.2, "appleContainer": 0.5, "docker": 0.3],
            defaultRuntime: .host
        )
        XCTAssertEqual(result["appleContainer"] ?? 0, 0.2, accuracy: 0.0001)
        // scale = (1 − 0.2) / (1 − 0.5) = 1.6: docker 0.3 × 1.6 = 0.48
        XCTAssertEqual(result["docker"] ?? 0, 0.48, accuracy: 0.0001)
        // tart 0.2 × 1.6 = 0.32
        XCTAssertEqual(result["tart"] ?? 0, 0.32, accuracy: 0.0001)
        // host (default) derives the remainder: 0 — omitted from the dict,
        // since ConfigLoader rejects an explicit 0.
        XCTAssertNil(result["host"])
        XCTAssertNil(BudgetEditor.validate(result))
    }

    func testSetShareToFullLeavesDefaultNothing() {
        let result = BudgetEditor.setShare(
            of: .appleContainer, to: 1.0,
            current: ["tart": 1.0],
            defaultRuntime: .tart
        )
        XCTAssertEqual(result["appleContainer"] ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertNil(result["tart"], "zero remainder is written by omission")
        // The pane used to alert-and-snap-back here: setShare stored an
        // explicit tart: 0, which validate refuses. Not any more.
        XCTAssertNil(BudgetEditor.validate(result))
    }

    func testSetShareToZeroOmitsTheKeyAndStaysValid() {
        let result = BudgetEditor.setShare(
            of: .appleContainer, to: 0,
            current: ["tart": 0.6, "appleContainer": 0.4],
            defaultRuntime: .tart
        )
        XCTAssertNil(result["appleContainer"], "zero share = omitted key")
        XCTAssertEqual(result["tart"] ?? 0, 1.0, accuracy: 0.0001, "the default absorbs everything")
        XCTAssertNil(BudgetEditor.validate(result))
    }

    func testSetShareOnTheDefaultRescalesTheOtherPools() {
        let result = BudgetEditor.setShare(
            of: .tart, to: 0.3,
            current: ["tart": 0.6, "appleContainer": 0.4],
            defaultRuntime: .tart
        )
        XCTAssertEqual(result["tart"] ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(result["appleContainer"] ?? 0, 0.7, accuracy: 0.0001)
        XCTAssertNil(BudgetEditor.validate(result))
    }

    func testDraggingADefaultThatOwnsEverythingSplitsTheShareEvenly() {
        // A fresh fleet: the default is at 100% and the other pools were
        // never budgeted (seeded explicit zeros, which the model adds so
        // the drag has pools to split with).
        let seeded = ["tart": 1.0, "appleContainer": 0.0, "docker": 0.0]
        let result = BudgetEditor.setShare(
            of: .tart, to: 0.3,
            current: seeded,
            defaultRuntime: .tart
        )
        XCTAssertEqual(result["tart"] ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(result["appleContainer"] ?? 0, 0.35, accuracy: 0.0001)
        XCTAssertEqual(result["docker"] ?? 0, 0.35, accuracy: 0.0001)
        XCTAssertNil(BudgetEditor.validate(result))
    }

    func testSetShareIsANormalizingNoOpWhenTheTargetMatches() {
        // Explicit zeros and a stored default that lies are cleaned up even
        // when the slider hasn't moved, so they can never reach the disk.
        let result = BudgetEditor.setShare(
            of: .appleContainer, to: 0.4,
            current: ["tart": 0.3, "appleContainer": 0.4, "docker": 0.0],
            defaultRuntime: .tart
        )
        XCTAssertNil(result["docker"])
        XCTAssertEqual(result["tart"] ?? 0, 0.6, accuracy: 0.0001, "the lying stored default is re-derived")
        XCTAssertEqual(result["appleContainer"] ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertNil(BudgetEditor.validate(result))
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

    // MARK: - addRuntime

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

    // MARK: - displayShares

    func testDisplaySharesFillsDefaultRemainder() {
        let shares = BudgetEditor.displayShares(current: ["appleContainer": 0.4], defaultRuntime: .tart)
        XCTAssertEqual(shares["tart"] ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertEqual(shares["appleContainer"] ?? 0, 0.4, accuracy: 0.0001)
    }

    func testDisplaySharesHandlesEmptyBudget() {
        let shares = BudgetEditor.displayShares(current: [:], defaultRuntime: .tart)
        XCTAssertEqual(shares["tart"] ?? 0, 1.0, accuracy: 0.0001)
    }

    // MARK: - validate

    func testValidateRejectsOutOfSumAndRange() {
        XCTAssertNil(BudgetEditor.validate(["tart": 0.6, "appleContainer": 0.4]))
        XCTAssertNil(BudgetEditor.validate(["tart": 1.0]))
        XCTAssertNotNil(BudgetEditor.validate(["tart": 0.7, "appleContainer": 0.7]))
        XCTAssertNotNil(BudgetEditor.validate(["tart": 0]))
        XCTAssertNotNil(BudgetEditor.validate(["tart": 1.5]))
    }

    // MARK: - starvedRoutes

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

    func testStarvedRoutesIsQuietWhenTheFleetIsNotPartitioned() {
        // No budget configured: pools read "cap n/a", so a missing cap entry
        // is not a starved route — nothing has been stranded by a split.
        let routes = [KinhinConfig.RuntimeConfig.Route(pattern: "acme/api", runtime: "appleContainer")]
        let warnings = BudgetEditor.starvedRoutes(
            routes: routes,
            caps: [.tart: 2, .appleContainer: 1],
            configuredRuntimes: [.tart, .appleContainer],
            isPartitioned: false
        )
        XCTAssertTrue(warnings.isEmpty)
    }

    func testStarvedRoutesNeverFlagsHostRoutes() {
        // Host runners draw no partitioned budget, so they have no cap
        // entry — a regression here warned that host routes "will never get
        // a runner" on every split.
        let routes = [KinhinConfig.RuntimeConfig.Route(pattern: "acme/scripts", runtime: "host")]
        let warnings = BudgetEditor.starvedRoutes(
            routes: routes,
            caps: [.tart: 0],
            configuredRuntimes: [.tart, .host]
        )
        XCTAssertTrue(warnings.isEmpty)
    }

    // MARK: - previewCaps

    /// A config with the given shapes (and this suite's reserve).
    private func previewConfig(container: (Int, Int)? = nil, docker: (Int, Int, Int)? = nil) -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.vm.cpuCount = 4
        cfg.vm.memoryGB = 8
        cfg.reserve = reserve
        if let container {
            cfg.container = KinhinConfig.ContainerConfig(image: "linux", cpus: container.0, memoryGB: container.1)
        }
        if let docker {
            cfg.docker = KinhinConfig.DockerForgeConfig(
                image: "linux", cpus: docker.0, memoryGB: docker.1, maxSlots: docker.2)
        }
        return cfg
    }

    func testPreviewCapsMatchPartitionMath() {
        let caps = BudgetEditor.previewCaps(
            config: previewConfig(container: (2, 4)), host: host,
            weights: ["tart": 0.6, "appleContainer": 0.4], defaultRuntime: .tart)
        // usable 10 cpu / 28 GB: container 0.4 → 4cpu/11GB ÷ (2,4) = 2;
        // tart remainder 6cpu/17GB ÷ (4,8) = 1.
        XCTAssertEqual(caps[.appleContainer], 2)
        XCTAssertEqual(caps[.tart], 1)
    }

    func testPreviewCapsAtSliderExtreme() {
        let caps = BudgetEditor.previewCaps(
            config: previewConfig(container: (2, 4)), host: host, weights: ["appleContainer": 1.0],
            defaultRuntime: .tart)
        // Everything to containers: 10÷2 = 5 (memory 28÷4 = 7, cpu binds).
        XCTAssertEqual(caps[.appleContainer], 5)
        XCTAssertEqual(caps[.tart], 0)
    }

    func testPreviewCapsEmptyWeightsGivesDefaultEverything() {
        let caps = BudgetEditor.previewCaps(
            config: previewConfig(), host: host, weights: [:], defaultRuntime: .tart)
        // No split: the whole usable budget in VM shape → 10÷4 = 2.
        XCTAssertEqual(caps[.tart], 2)
    }

    /// The preview is the engine's partition: host slots cost (1,1), not
    /// the VM shape, and Docker's slot cap applies on top of its share.
    func testPreviewCapsMatchTheEngineForHostAndDocker() {
        var cfg = previewConfig(docker: (2, 4, 3))
        cfg.runtimes = KinhinConfig.RuntimeConfig(
            defaultRuntime: "tart", budget: ["docker": 0.8, "host": 0.1], routes: [])
        let weights = cfg.runtimes?.budget ?? [:]
        let preview = BudgetEditor.previewCaps(config: cfg, host: host, weights: weights, defaultRuntime: .tart)
        XCTAssertEqual(preview[.docker], 3, "8 cpu ÷ 2 = 4, capped at max_slots 3")
        XCTAssertEqual(preview[.host], 1, "host slots are (1,1): 1 cpu ÷ 1")
        XCTAssertEqual(preview, RuntimeCapacity.caps(for: cfg, host: host), "preview must equal the engine's caps")
    }

    // MARK: - Round-trip through the validated config editor

    func testBudgetRoundTripThroughConfigEditor() throws {
        let base = """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
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
