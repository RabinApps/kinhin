import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class RuntimesTabTests: XCTestCase {
    private var model: RuntimesModel!

    override func setUp() async throws {
        try await super.setUp()
        model = RuntimesModel()
    }

    // MARK: availability titles

    func testAvailabilityTitleDistinguishesInstalledFromNotInstalled() {
        XCTAssertEqual(
            RuntimesModel.availabilityTitle(.tart, health: .ready, inUse: true),
            "🍎 Tart (macOS VMs) — installed ✓ · used by your fleet"
        )
        XCTAssertEqual(
            RuntimesModel.availabilityTitle(
                .docker, health: .missing(tool: "docker", fix: "install Docker Desktop"), inUse: false),
            "🐳 Docker (Linux) — not installed · not used by your config"
        )
        XCTAssertEqual(
            RuntimesModel.availabilityTitle(
                .appleContainer, health: .broken("the container system service is not running"), inUse: true),
            "🐧 Apple container (Linux) — installed — needs attention · used by your fleet"
        )
    }

    func testAvailabilityTitlesAreDistinctPerState() {
        let titles = [
            RuntimesModel.availabilityTitle(.tart, health: .ready, inUse: false),
            RuntimesModel.availabilityTitle(.tart, health: .missing(tool: "tart", fix: "x"), inUse: false),
            RuntimesModel.availabilityTitle(.tart, health: .broken("y"), inUse: false),
        ]
        XCTAssertEqual(Set(titles).count, 3, "the three states must read differently at a glance")
    }

    func testHealthChipsCoverEveryState() {
        XCTAssertEqual(RuntimesModel.healthChip(.ready, probing: false).text, "● ready")
        XCTAssertEqual(
            RuntimesModel.healthChip(.missing(tool: "docker", fix: ""), probing: false).text, "● docker missing")
        XCTAssertEqual(RuntimesModel.healthChip(.broken("x"), probing: false).text, "● error")
        XCTAssertEqual(RuntimesModel.healthChip(nil, probing: true).text, "● checking…")
        XCTAssertEqual(RuntimesModel.healthChip(nil, probing: false).text, "")
    }

    // MARK: view model availability sweep (KinhinKit)

    func testAvailabilityCoversAllRuntimesEvenUnconfigured() async {
        // Minimal config: no container:, no docker: — those runtimes must
        // still appear in the sweep, which is the whole point.
        let yaml = """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            """
        let vm = await RuntimesPaneViewModel.load(
            configYAML: yaml,
            host: HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 94, arm64: true),
            reserve: .default,
            loadHealth: true,
            tartHealth: { .ready },
            containerHealth: { .missing(tool: "apple container", fix: "brew install container") }
        )
        XCTAssertEqual(Set(vm.availability.keys), [.tart, .appleContainer, .docker])
        XCTAssertEqual(vm.availability[.tart], .ready)
        // Docker has no injection point: the real probe runs. On CI and dev
        // Macs without Docker it reports missing rather than being absent.
        guard case .missing = vm.availability[.docker] else {
            if case .ready = vm.availability[.docker] { return }  // Docker present locally — fine
            return XCTFail(
                "docker availability should be ready or missing, got: \(String(describing: vm.availability[.docker]))")
        }
    }

    // MARK: config editor (KinhinKit)

    private func tempConfig(_ text: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-editor-test-\(UUID().uuidString).yaml")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let validConfig = """
        repo: "acme/widgets"
        labels: ["self-hosted", "macos", "arm64"]
        """

    private let invalidConfig = """
        repo: ""
        labels: ["self-hosted"]
        """

    func testEditorWritesWhenValidationPasses() throws {
        let url = tempConfig(validConfig)
        defer { try? FileManager.default.removeItem(at: url) }

        let edited = validConfig + "\nmax_runners: 6\n"
        let written = try ConfigEditor.save(edited, to: url)
        XCTAssertEqual(written, edited)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), edited)
    }

    func testEditorRefusesInvalidYAMLAndLeavesFileUntouched() throws {
        let url = tempConfig(validConfig)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ConfigEditor.save("repo: [unclosed", to: url)) { error in
            guard case ConfigEditError.rejected = error else {
                return XCTFail("expected a validation error, got: \(error)")
            }
            // The engine's message is opaque for a YAML parse failure, but the
            // file must be untouched either way.
        }
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8), validConfig,
            "a rejected edit must never touch the file")
    }

    func testEditorRefusesSemanticallyInvalidConfig() throws {
        let url = tempConfig(validConfig)
        defer { try? FileManager.default.removeItem(at: url) }

        // Parses as YAML but fails the engine's validation (empty repo).
        XCTAssertThrowsError(try ConfigEditor.save(invalidConfig, to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), validConfig)
    }

    func testEditorReportsMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-missing-\(UUID().uuidString).yaml")
        XCTAssertThrowsError(try ConfigEditor.save(validConfig, to: url))
    }

    // MARK: the model against a real scratch config

    private func loadedModel(_ yaml: String) async -> RuntimesModel {
        let url = tempConfig(yaml)
        let model = RuntimesModel()
        model.configURL = url
        model.reload()
        for _ in 0..<100 where !model.hasLoadedForTesting {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return model
    }

    func testModelLoadsPoolsRoutesAndLabels() async {
        let model = await loadedModel(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            fleet: none
            """)
        defer { try? FileManager.default.removeItem(at: model.configURL) }
        XCTAssertEqual(model.headline, "Fleet scope: acme/widgets — single-pool fleet")
        XCTAssertTrue(model.hasLoadedForTesting)
        XCTAssertFalse(model.loadFailed)
        XCTAssertEqual(model.fleetLabelsText, "self-hosted")
    }

    func testModelReportsABrokenConfigInsteadOfRenderingNothing() async {
        let model = await loadedModel("repo: [unclosed\n")
        defer { try? FileManager.default.removeItem(at: model.configURL) }
        XCTAssertTrue(model.loadFailed, "a broken config must be named, never silently blank")
        XCTAssertTrue(model.emptyMessage.contains("config.yaml has a problem"))
    }

    func testMissingConfigExplainsItself() async {
        let model = RuntimesModel()
        model.configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-missing-\(UUID().uuidString).yaml")
        model.reload()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(model.loadFailed)
        XCTAssertTrue(model.emptyMessage.contains("No config file yet"))
    }
}
