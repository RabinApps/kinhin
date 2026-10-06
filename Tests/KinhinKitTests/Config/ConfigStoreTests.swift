import XCTest

@testable import KinhinKit

final class ConfigStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-configstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("config.yaml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testMissingFileReadsAsEmptyText() throws {
        XCTAssertEqual(try ConfigStore.text(at: dir.appendingPathComponent("nope.yaml")), "")
    }

    func testUnreadableFileThrowsInsteadOfReadingAsEmpty() {
        // A directory exists at the path but cannot be read as text.
        XCTAssertThrowsError(try ConfigStore.text(at: dir)) { error in
            XCTAssertEqual(error as? ConfigError, .unreadable(dir.path))
        }
    }

    func testSnapshotIsNilWhenThereIsNothingConfiguredYet() throws {
        XCTAssertNil(try ConfigStore.snapshot(at: dir.appendingPathComponent("nope.yaml")))
        XCTAssertNil(try ConfigStore.snapshot(at: write("  \n")))
    }

    func testSnapshotThrowsWhenTopLevelIsNotAMapping() throws {
        let url = try write("- just\n- a list\n")
        XCTAssertThrowsError(try ConfigStore.snapshot(at: url)) { error in
            XCTAssertEqual(error as? ConfigEditError, .yamlParse("top level must be a mapping"))
        }
    }

    func testSnapshotReadsValidConfig() throws {
        let url = try write("accounts:\n  - name: github\n    forge: github\n    scope: acme/widgets\nmax_runners: 3\n")
        let snapshot = try XCTUnwrap(ConfigStore.snapshot(at: url))
        XCTAssertEqual(snapshot.maxRunners, 3)
    }

    /// `tart_path:` reaches the UI through the snapshot, so a form that
    /// probes tart can honor the override (the same rule the CLI, doctor and
    /// daemon apply) instead of searching PATH behind the config's back.
    func testSnapshotCarriesTheConfiguredTartPath() throws {
        let overridden = try write("tart_path: \"/opt/custom/tart\"\n")
        XCTAssertEqual(try XCTUnwrap(ConfigStore.snapshot(at: overridden)).tartPath, "/opt/custom/tart")
        let plain = try write("max_runners: 2\n")
        XCTAssertNil(try XCTUnwrap(ConfigStore.snapshot(at: plain)).tartPath, "absent = trust the probe's search")
    }

    func testTextOrLogNeverThrows() throws {
        XCTAssertEqual(ConfigStore.textOrLog(at: dir), "")
    }
}
