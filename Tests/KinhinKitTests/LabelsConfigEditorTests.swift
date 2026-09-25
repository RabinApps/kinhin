import XCTest
import Yams

@testable import KinhinKit

/// Editing the fleet's base labels and container.labels: targeted text
/// surgery that preserves the rest of the file, refuses invalid writes,
/// and keeps the container pool's marker label intact (routing safety).
final class LabelsConfigEditorTests: XCTestCase {
    private let baseConfig = """
        # kinhin configuration
        repo: "acme/ios-app"

        labels: ["self-hosted", "macos", "arm64"]

        max_runners: 4

        container:
          image: "kinhin-ci-linux"
          cpus: 2
          memory_gb: 4
        """

    private func tempConfig(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-labels-\(UUID().uuidString).yaml")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Reading

    func testReadsBothScopes() throws {
        XCTAssertEqual(LabelsConfigEditor.labels(in: baseConfig, scope: .fleet), ["self-hosted", "macos", "arm64"])
        XCTAssertEqual(LabelsConfigEditor.labels(in: baseConfig, scope: .container), [])
    }

    func testReadsContainerLabelsWhenPresent() throws {
        let yaml = baseConfig + "\n  labels: [\"gpu\", \"kinhin-extra\"]\n"
        XCTAssertEqual(LabelsConfigEditor.labels(in: yaml, scope: .container), ["gpu", "kinhin-extra"])
    }

    // MARK: Fleet scope

    func testApplyFleetLabelsReplacesInPlaceAndPreservesComments() throws {
        let url = try tempConfig(baseConfig)
        defer { try? FileManager.default.removeItem(at: url) }

        try LabelsConfigEditor.apply(["self-hosted", "macos-15", "arm64", "kinhin-vm"], scope: .fleet, to: url)
        let updated = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(updated.contains("# kinhin configuration"))
        XCTAssertTrue(
            updated.contains("labels:\n  - \"self-hosted\"\n  - \"macos-15\"\n  - \"arm64\"\n  - \"kinhin-vm\""))
        // Still parses, and the value round-trips.
        let cfg = try ConfigLoader.load(from: url)
        XCTAssertEqual(cfg.labels, ["self-hosted", "macos-15", "arm64", "kinhin-vm"])
    }

    func testApplyFleetLabelsAppendsWhenKeyAbsent() throws {
        let withoutLabels = baseConfig.replacingOccurrences(
            of: "\nlabels: [\"self-hosted\", \"macos\", \"arm64\"]\n", with: "\n")
        let url = try tempConfig(withoutLabels)
        defer { try? FileManager.default.removeItem(at: url) }

        try LabelsConfigEditor.apply(["self-hosted", "macos"], scope: .fleet, to: url)
        let cfg = try ConfigLoader.load(from: url)
        XCTAssertEqual(cfg.labels, ["self-hosted", "macos"])
    }

    func testApplyFleetLabelsRejectsEmptyList() throws {
        let url = try tempConfig(baseConfig)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try LabelsConfigEditor.apply([], scope: .fleet, to: url)) { error in
            guard case RuntimesConfigError.validation = error else { return XCTFail("wrong error: \(error)") }
        }
        // Disk untouched.
        XCTAssertEqual(
            LabelsConfigEditor.labels(in: try String(contentsOf: url, encoding: .utf8), scope: .fleet),
            ["self-hosted", "macos", "arm64"])
    }

    // MARK: Container scope

    func testApplyContainerLabelsInsertsIntoContainerBlock() throws {
        let url = try tempConfig(baseConfig)
        defer { try? FileManager.default.removeItem(at: url) }

        try LabelsConfigEditor.apply(["linux", "kinhin-extra"], scope: .container, to: url)
        let updated = try String(contentsOf: url, encoding: .utf8)

        // Inside the container block, image untouched.
        XCTAssertTrue(
            updated.contains(
                "container:\n  labels:\n    - \"linux\"\n    - \"kinhin-extra\"\n  image: \"kinhin-ci-linux\""))
        let cfg = try ConfigLoader.load(from: url)
        XCTAssertEqual(cfg.container?.labels, ["linux", "kinhin-extra"])
        // Top-level labels untouched.
        XCTAssertEqual(cfg.labels, ["self-hosted", "macos", "arm64"])
    }

    func testApplyContainerLabelsReplacesExistingList() throws {
        let withLabels = baseConfig + "\n  labels: [\"old-one\"]\n"
        let url = try tempConfig(withLabels)
        defer { try? FileManager.default.removeItem(at: url) }

        try LabelsConfigEditor.apply(["new-one"], scope: .container, to: url)
        let cfg = try ConfigLoader.load(from: url)
        XCTAssertEqual(cfg.container?.labels, ["new-one"])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("old-one"))
    }

    func testApplyContainerLabelsWithoutContainerSectionFails() throws {
        let noContainer = """
            repo: "acme/ios-app"
            labels: ["self-hosted"]
            """
        let url = try tempConfig(noContainer)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try LabelsConfigEditor.apply(["x"], scope: .container, to: url)) { error in
            guard case RuntimesConfigError.validation = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    // MARK: Routing safety

    func testContainerMarkerLabelSurvivesArbitraryEdits() throws {
        // The kinhin-container marker is what makes per-job routing safe;
        // it's added at pool construction (config never needs it), but an
        // edit must never *break* a user who put it in the file explicitly.
        let withMarker = baseConfig + "\n  labels: [\"kinhin-container\"]\n"
        let url = try tempConfig(withMarker)
        defer { try? FileManager.default.removeItem(at: url) }

        try LabelsConfigEditor.apply(["gpu", "kinhin-container"], scope: .container, to: url)
        let cfg = try ConfigLoader.load(from: url)
        XCTAssertTrue(cfg.container?.labels?.contains("kinhin-container") ?? false)

        // Pool construction still yields exactly one marker (dedup at build).
        let model = RuntimeConfigModel(
            config: cfg.runtimes, fleetLabels: cfg.labels, containerLabels: cfg.container?.labels,
            containerConfigured: true)
        let containerPool = model.pools[.appleContainer]
        XCTAssertEqual(containerPool?.labels.filter { $0 == "kinhin-container" }.count, 1)
    }

    // MARK: Validation gating

    func testInvalidGlobalConfigStillBlocksWrite() throws {
        // Removing repo: makes the file invalid regardless of labels.
        let broken = baseConfig.replacingOccurrences(of: "repo: \"acme/ios-app\"", with: "# repo removed")
        let url = try tempConfig(broken)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try LabelsConfigEditor.apply(["self-hosted"], scope: .fleet, to: url))
    }

    // MARK: Flow-style round-trip

    func testFleetLabelsInFlowStyleAreReplacedCleanly() throws {
        // The starter template uses flow style: labels: ["a", "b"]. The
        // edit converts just that key to block style.
        let url = try tempConfig(baseConfig)
        defer { try? FileManager.default.removeItem(at: url) }

        try LabelsConfigEditor.apply(["one", "two"], scope: .fleet, to: url)
        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(updated.contains("["), "flow-style brackets for labels should be gone")
        XCTAssertTrue(updated.contains("labels:\n  - \"one\"\n  - \"two\""))
    }
}
