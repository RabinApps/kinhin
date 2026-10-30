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

    func testHealthChipsCoverEveryState() {
        XCTAssertEqual(RuntimesModel.healthChip(.ready, probing: false).text, "● ready")
        XCTAssertEqual(
            RuntimesModel.healthChip(.missing(tool: "docker", fix: ""), probing: false).text, "● docker missing")
        XCTAssertEqual(RuntimesModel.healthChip(.broken("x"), probing: false).text, "● error")
        XCTAssertEqual(RuntimesModel.healthChip(nil, probing: true).text, "● checking…")
        XCTAssertEqual(RuntimesModel.healthChip(nil, probing: false).text, "")
    }

    // MARK: - view model availability sweep (KinhinKit)

    func testAvailabilityCoversAllRuntimesEvenUnconfigured() async {
        // Minimal config: no container:, no docker: — those runtimes must
        // still appear in the sweep, which is the whole point.
        let yaml = """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
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
        // Macs without Docker it reports missing rather than being absent, and
        // on a Mac whose docker CLI is installed while the daemon is down it
        // reports broken — either way the availability sweep covers docker.
        guard case .missing = vm.availability[.docker] else {
            switch vm.availability[.docker] {
            case .ready, .broken: return  // Docker present locally (or its CLI with a down daemon) — fine
            default:
                return XCTFail(
                    "docker availability should be ready, missing or broken, got: \(String(describing: vm.availability[.docker]))"
                )
            }
        }
    }

    // MARK: - config editor (KinhinKit)

    private func tempConfig(_ text: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-editor-test-\(UUID().uuidString).yaml")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let validConfig = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: ["self-hosted", "macos", "arm64"]
        """

    private let invalidConfig = """
        accounts:
          - name: github
            forge: github
            scope: ""
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

        XCTAssertThrowsError(try ConfigEditor.save("accounts: [unclosed", to: url)) { error in
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

    // MARK: - the model against a real scratch config

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
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            """)
        defer { try? FileManager.default.removeItem(at: model.configURL) }
        XCTAssertEqual(model.headline, "Fleet scope: acme/widgets — single-pool fleet")
        XCTAssertTrue(model.hasLoadedForTesting)
        XCTAssertFalse(model.loadFailed)
        XCTAssertEqual(model.fleetLabelsText, "self-hosted")
    }

    func testModelReportsABrokenConfigInsteadOfRenderingNothing() async {
        let model = await loadedModel("accounts: [unclosed\n")
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
