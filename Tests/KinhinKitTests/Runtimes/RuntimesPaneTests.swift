import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Runtimes pane: config section editing that preserves the rest of the
/// YAML file, refuses invalid writes, and a read model that matches the
/// engine's pool/capacity math.
final class RuntimesPaneTests: XCTestCase {
    // MARK: - Fixtures

    private let baseConfig = """
        # kinhin configuration
        accounts:
          - name: github
            forge: github
            scope: "acme/ios-app"

        labels: ["self-hosted", "macos", "arm64"]

        max_runners: 4

        vm:
          cpu: 4
          memory_gb: 8

        image: "tahoe-base"

        reserve:
          cpu: 2
          memory_gb: 4
        """

    private func configWithContainer() -> String {
        baseConfig + "\n\ncontainer:\n  image: \"kinhin-ci-linux\"\n  cpus: 2\n  memory_gb: 4\n"
    }

    private let testHost = HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 94, arm64: true)

    // MARK: - Editor: reading

    func testParsedReturnsNilWhenSectionAbsent() throws {
        try XCTAssertNil(RuntimesConfigEditor.parsed(from: baseConfig))
    }

    func testParsedReadsFullSection() throws {
        let yaml =
            baseConfig
            + "\nruntimes:\n  default: appleContainer\n  budget: {tart: 0.6, appleContainer: 0.4}\n  routes:\n    - pattern: \"acme/api\"\n      runtime: appleContainer\n"
        let rc = try XCTUnwrap(RuntimesConfigEditor.parsed(from: yaml))
        XCTAssertEqual(rc.defaultRuntime, .appleContainer)
        XCTAssertEqual(rc.budget["tart"] ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertEqual(rc.routes.count, 1)
        XCTAssertEqual(rc.routes.first?.pattern, "acme/api")
    }

    // MARK: - Editor: applying (comment preservation)

    func testApplyWritesSectionAndPreservesCommentsAndOrder() throws {
        // The section references appleContainer, so the fixture needs the
        // container: section for engine validation to accept the write.
        let url = try tempConfig(configWithContainer())
        defer { try? FileManager.default.removeItem(at: url) }

        let rc = KinhinConfig.RuntimeConfig(
            defaultRuntime: .tart,
            budget: ["tart": 0.6, "appleContainer": 0.4],
            routes: [KinhinConfig.RuntimeConfig.Route(pattern: "acme/api", runtime: .appleContainer)]
        )
        let updated = try RuntimesConfigEditor.apply(rc, to: url)

        // Comments above and between sections survive.
        XCTAssertTrue(updated.contains("# kinhin configuration"))
        XCTAssertTrue(updated.contains("labels: [\"self-hosted\", \"macos\", \"arm64\"]"))
        // New section landed at the end.
        XCTAssertTrue(updated.contains("runtimes:\n  default: tart"))
        XCTAssertTrue(updated.contains("- pattern: \"acme/api\""))
        // Everything parses through the real loader.
        let cfg = try ConfigLoader.load(from: url)
        XCTAssertEqual(cfg.runtimes?.routes.first?.runtime, .appleContainer)
    }

    func testApplyReplacesExistingSectionInPlace() throws {
        let withSection =
            configWithContainer()
            + "\nruntimes:\n  default: tart\n  routes:\n    - pattern: \"acme/old\"\n      runtime: tart\n"
        let url = try tempConfig(withSection)
        defer { try? FileManager.default.removeItem(at: url) }

        let rc = KinhinConfig.RuntimeConfig(
            defaultRuntime: .appleContainer,
            budget: ["appleContainer": 0.5],
            routes: []
        )
        let updated = try RuntimesConfigEditor.apply(rc, to: url)

        // Exactly one runtimes section.
        XCTAssertEqual(updated.components(separatedBy: "runtimes:").count - 1, 1)
        // Old routes gone, new default in place.
        XCTAssertFalse(updated.contains("acme/old"))
        XCTAssertTrue(updated.contains("default: appleContainer"))
        // The section still sits after reserve: (in-place replacement).
        let reserveIdx = try XCTUnwrap(updated.range(of: "memory_gb: 4"))
        let runtimesIdx = try XCTUnwrap(updated.range(of: "runtimes:"))
        XCTAssertTrue(reserveIdx.lowerBound < runtimesIdx.lowerBound)
    }

    func testApplyRejectsConfigThatFailsEngineValidation() throws {
        let url = try tempConfig(baseConfig)
        defer { try? FileManager.default.removeItem(at: url) }

        // Routes reference appleContainer but the config has no container:
        // section — the engine's own validation must reject the write.
        let rc = KinhinConfig.RuntimeConfig(
            defaultRuntime: .tart,
            budget: [:],
            routes: [KinhinConfig.RuntimeConfig.Route(pattern: "acme/api", runtime: .appleContainer)]
        )
        XCTAssertThrowsError(try RuntimesConfigEditor.apply(rc, to: url)) { error in
            guard case ConfigEditError.validation = error else {
                return XCTFail("expected validation error, got \(error)")
            }
        }
        // Disk untouched.
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("runtimes:"))
    }

    func testApplyToMissingFileThrowsNotFound() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-nope-\(UUID().uuidString).yaml")
        XCTAssertThrowsError(try RuntimesConfigEditor.apply(KinhinConfig.RuntimeConfig(), to: url)) { error in
            guard case ConfigEditError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func testSectionTextIsQuotedAndWeightFormatted() {
        let rc = KinhinConfig.RuntimeConfig(
            defaultRuntime: .tart,
            budget: ["appleContainer": 0.35, "tart": 0.65],
            routes: [KinhinConfig.RuntimeConfig.Route(pattern: "acme/x@Build & Test", runtime: .appleContainer)]
        )
        let text = RuntimesConfigEditor.sectionText(rc)
        XCTAssertTrue(text.contains("budget:"))
        XCTAssertTrue(text.contains("appleContainer: 0.35"))
        // Budget sorted by name for stable diffs.
        let appleIdx = try! XCTUnwrap(text.range(of: "appleContainer")).lowerBound
        let tartIdx = try! XCTUnwrap(text.range(of: "tart:")).lowerBound
        XCTAssertTrue(appleIdx < tartIdx)
        // Patterns with special chars quoted.
        XCTAssertTrue(text.contains("- pattern: \"acme/x@Build & Test\""))
    }

    // MARK: - View model

    func testViewModelSinglePoolWithoutRuntimesSection() async throws {
        let yaml = configWithContainer()
        let vm = await RuntimesPaneViewModel.load(configYAML: yaml, host: testHost, reserve: .default)
        XCTAssertFalse(vm.routingConfigured)
        XCTAssertTrue(vm.containerConfigured)
        // Single pool: container-only fleet keeps legacy behavior.
        XCTAssertEqual(vm.pools.map(\.runtime), [.appleContainer])
        XCTAssertTrue(vm.routes.isEmpty)
        XCTAssertEqual(vm.defaultRuntime, .appleContainer)
        // Cap comes from the full Capacity.plan (no partition): 8 usable cpu
        // ÷ 2 = 4, 60 GB ÷ 4 = 15, user max_runners 4 → 4.
        XCTAssertEqual(vm.pools.first?.cap, 4)
        // Pool labels carry the container marker (per-job opt-in).
        XCTAssertTrue(vm.pools.first?.labels.contains("kinhin-container") ?? false)
    }

    func testViewModelMixedFleetPoolsCapsAndRoutes() async throws {
        let yaml =
            configWithContainer()
            + "\nruntimes:\n  default: tart\n  budget: {tart: 0.6, appleContainer: 0.4}\n  routes:\n    - pattern: \"acme/api\"\n      runtime: appleContainer\n    - pattern: \"acme/web@Nightly\"\n      runtime: appleContainer\n"
        let vm = await RuntimesPaneViewModel.load(configYAML: yaml, host: testHost, reserve: .default)

        XCTAssertTrue(vm.routingConfigured)
        XCTAssertEqual(vm.defaultRuntime, .tart)

        // Two pools, both present.
        XCTAssertEqual(Set(vm.pools.map(\.runtime)), [.tart, .appleContainer])

        // Caps from the same partition math the engine uses:
        // usable = 10-2 = 8 cpu, 64-4 = 60 GB.
        // appleContainer 0.4: 3.2→3 cpu / 24 GB ÷ (2 cpu, 4 GB) = 1 (cpu-bound)
        // tart remainder: 8-3 = 5 cpu / 36 GB ÷ (4 cpu, 8 GB) = 1 (cpu-bound)
        let tartCap = try XCTUnwrap(vm.pools.first { $0.runtime == .tart }?.cap)
        let containerCap = try XCTUnwrap(vm.pools.first { $0.runtime == .appleContainer }?.cap)
        XCTAssertEqual(tartCap, 1)
        XCTAssertEqual(containerCap, 1)

        // Budget percentages surfaced.
        XCTAssertEqual(vm.pools.first { $0.runtime == .tart }?.budgetPercent ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(vm.pools.first { $0.runtime == .appleContainer }?.budgetPercent ?? 0, 40, accuracy: 0.01)

        // Routes in order with workflow flags.
        XCTAssertEqual(vm.routes.count, 2)
        XCTAssertEqual(vm.routes[0].pattern, "acme/api")
        XCTAssertFalse(vm.routes[0].isWorkflow)
        XCTAssertEqual(vm.routes[1].pattern, "acme/web@Nightly")
        XCTAssertTrue(vm.routes[1].isWorkflow)
        XCTAssertEqual(vm.routes[1].runtime, .appleContainer)
    }

    func testViewModelLabelsIncludePoolMarkers() async throws {
        let yaml =
            configWithContainer()
            + "\nruntimes:\n  default: tart\n  routes:\n    - pattern: \"acme/api\"\n      runtime: appleContainer\n"
        let vm = await RuntimesPaneViewModel.load(configYAML: yaml, host: testHost, reserve: .default)
        let tart = try XCTUnwrap(vm.pools.first { $0.runtime == .tart })
        let container = try XCTUnwrap(vm.pools.first { $0.runtime == .appleContainer })
        // Tart pool carries the fleet labels verbatim.
        XCTAssertEqual(tart.labels, ["self-hosted", "macos", "arm64"])
        // Container pool adds the exclusive marker.
        XCTAssertTrue(container.labels.contains("kinhin-container"))
        // The two label sets are disjoint on the marker — that's what makes
        // per-job routing safe.
        XCTAssertFalse(tart.labels.contains("kinhin-container"))
    }

    // MARK: - Health probing

    func testHealthProbesAttachToPoolRows() async throws {
        let yaml = configWithContainer() + "\nruntimes:\n  default: tart\n  budget: {tart: 0.6, appleContainer: 0.4}\n"
        let vm = await RuntimesPaneViewModel.load(
            configYAML: yaml,
            host: testHost,
            reserve: .default,
            loadHealth: true,
            tartHealth: { .ready },
            containerHealth: { .broken("the container system service is not running") }
        )
        let tart = try XCTUnwrap(vm.pools.first { $0.runtime == .tart })
        let container = try XCTUnwrap(vm.pools.first { $0.runtime == .appleContainer })
        XCTAssertEqual(tart.health, .ready)
        XCTAssertEqual(container.health, .broken("the container system service is not running"))
    }

    func testHealthNilWhenNotProbed() async throws {
        let vm = await RuntimesPaneViewModel.load(configYAML: configWithContainer(), host: testHost, reserve: .default)
        // Default loadHealth: false — pure math, no probes, no nil surprises
        // for pools that exist.
        for pool in vm.pools {
            XCTAssertNil(pool.health)
        }
    }

    func testTartControllerConstructionFailureReportsMissing() async throws {
        // tart_path pointing at nothing forces construction to fail regardless
        // of whether this Mac happens to have tart installed.
        let yaml =
            configWithContainer()
            + "\ntart_path: \"/nonexistent/kinhin-test-tart\"\nruntimes:\n  default: tart\n"
        let vm = await RuntimesPaneViewModel.load(
            configYAML: yaml,
            host: testHost,
            reserve: .default,
            loadHealth: true,
            tartHealth: nil,  // no injection: real path; construction fails on the missing override
            containerHealth: { .ready }
        )
        let tart = try XCTUnwrap(vm.pools.first { $0.runtime == .tart })
        let container = try XCTUnwrap(vm.pools.first { $0.runtime == .appleContainer })
        // Controller construction failure IS the health answer for tart.
        XCTAssertEqual(
            tart.health,
            .missing(
                tool: "tart", fix: "brew tap openai/tools && brew trust openai/tools && brew install openai/tools/tart")
        )
        XCTAssertEqual(container.health, .ready)
    }

    func testHealthNoteMapping() {
        XCTAssertNil(RuntimesPaneViewModel.healthNote(for: nil))
        XCTAssertNil(RuntimesPaneViewModel.healthNote(for: .ready))
        XCTAssertEqual(
            RuntimesPaneViewModel.healthNote(for: .missing(tool: "tart", fix: "brew install tart")),
            "tart: not installed — brew install tart"
        )
        XCTAssertEqual(
            RuntimesPaneViewModel.healthNote(for: .broken("service is down")),
            "service is down"
        )
    }

    func testTartHealthProbesTheConfiguredTartPath() async throws {
        // A configured tart outside the trusted directories reads ready: the
        // health probe runs the configured binary, never a PATH lookalike.
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-test-tart-\(UUID().uuidString)")
        try "#!/bin/sh\necho tart version 2.32.1\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        defer { try? FileManager.default.removeItem(at: stub) }  // temp fixture; leftover is harmless

        let yaml = baseConfig + "\ntart_path: \"\(stub.path)\"\nruntimes:\n  default: tart\n"
        let vm = await RuntimesPaneViewModel.load(
            configYAML: yaml,
            host: testHost,
            reserve: .default,
            loadHealth: true,
            tartHealth: nil,  // no injection: real probe against the configured binary
            containerHealth: { .ready }
        )
        let tart = try XCTUnwrap(vm.pools.first { $0.runtime == .tart })
        XCTAssertEqual(tart.health, .ready)
    }

    // MARK: - Helpers

    private func tempConfig(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-runtimes-\(UUID().uuidString).yaml")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
