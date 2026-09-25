import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class RuntimesTabTests: XCTestCase {
    private var controller: RuntimesWindowController!

    override func setUp() {
        super.setUp()
        controller = RuntimesWindowController(embeddedIn: NSView())
    }

    // MARK: availability titles

    func testAvailabilityTitleDistinguishesInstalledFromNotInstalled() {
        XCTAssertEqual(
            RuntimesWindowController.availabilityTitle(.tart, health: .ready, inUse: true),
            "🍎 Tart (macOS VMs) — installed ✓ · used by your fleet"
        )
        XCTAssertEqual(
            RuntimesWindowController.availabilityTitle(
                .docker, health: .missing(tool: "docker", fix: "install Docker Desktop"), inUse: false),
            "🐳 Docker (Linux) — not installed · not used by your config"
        )
        XCTAssertEqual(
            RuntimesWindowController.availabilityTitle(
                .appleContainer, health: .broken("the container system service is not running"), inUse: true),
            "🐧 Apple container (Linux) — installed — needs attention · used by your fleet"
        )
    }

    func testAvailabilityTitlesAreDistinctPerState() {
        let titles = [
            RuntimesWindowController.availabilityTitle(.tart, health: .ready, inUse: false),
            RuntimesWindowController.availabilityTitle(.tart, health: .missing(tool: "tart", fix: "x"), inUse: false),
            RuntimesWindowController.availabilityTitle(.tart, health: .broken("y"), inUse: false),
        ]
        XCTAssertEqual(Set(titles).count, 3, "the three states must read differently at a glance")
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
}
