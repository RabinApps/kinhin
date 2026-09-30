import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class SetBaseImageTests: XCTestCase {
    private func file(_ yaml: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let both =
        "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [self-hosted]\n# keep me\ncontainer:\n  image: \"c\"\ndocker:\n  image: \"d\"\n"

    func testSetsEachRuntimeIndependentlyAndKeepsComments() throws {
        let url = try file(both)
        try GeneralConfigEditor.setBaseImage("debian:12", for: .appleContainer, at: url)
        try GeneralConfigEditor.setBaseImage("ubuntu:22.04", for: .docker, at: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# keep me"))
        let cfg = try ConfigLoader.load(from: url)
        XCTAssertEqual(cfg.container?.baseImage, "debian:12")
        XCTAssertEqual(cfg.docker?.baseImage, "ubuntu:22.04")
        let snapshot = try XCTUnwrap(ConfigStore.snapshot(at: url))
        XCTAssertEqual(snapshot.baseImage(for: .docker), "ubuntu:22.04")

        try GeneralConfigEditor.setBaseImage(nil, for: .docker, at: url)
        XCTAssertNil(try ConfigLoader.load(from: url).docker?.baseImage)
        XCTAssertEqual(try ConfigLoader.load(from: url).container?.baseImage, "debian:12")
    }

    func testRefusesWhenTheRuntimeIsNotConfiguredOrNotLinux() throws {
        let url = try file(
            "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [self-hosted]\ndocker:\n  image: \"d\"\n"
        )
        XCTAssertThrowsError(try GeneralConfigEditor.setBaseImage("debian:12", for: .appleContainer, at: url))
    }

    func testTartBaseImageRoundTripsAndClearsToTheDefault() throws {
        let url = try file(both)
        try GeneralConfigEditor.setBaseImage("ghcr.io/cirruslabs/macos-sequoia-base:latest", for: .tart, at: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("base_image: \"ghcr.io/cirruslabs/macos-sequoia-base:latest\""), written)
        XCTAssertTrue(written.contains("# keep me"), "the edit must not disturb the rest of the file")
        let cfg = try ConfigLoader.load(from: url)
        XCTAssertEqual(cfg.baseImage, "ghcr.io/cirruslabs/macos-sequoia-base:latest")
        let snapshot = try XCTUnwrap(ConfigStore.snapshot(at: url))
        XCTAssertEqual(snapshot.baseImage(for: .tart), cfg.baseImage)

        // Clearing removes the key: the default must never be pinned in.
        try GeneralConfigEditor.setBaseImage(nil, for: .tart, at: url)
        let cleared = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(cleared.contains("base_image:"), cleared)
        XCTAssertNil(try ConfigLoader.load(from: url).baseImage)
    }

    /// Clearing tart's base image must remove the top-level key, not an
    /// indented `base_image:` inside an earlier `container:`/`docker:` block.
    func testClearingTartBaseImageLeavesSectionBaseImagesAlone() throws {
        let url = try file(both)
        try GeneralConfigEditor.setBaseImage("debian:12", for: .appleContainer, at: url)
        try GeneralConfigEditor.setBaseImage("ghcr.io/cirruslabs/macos-sequoia-base:latest", for: .tart, at: url)

        try GeneralConfigEditor.setBaseImage(nil, for: .tart, at: url)

        let cfg = try ConfigLoader.load(from: url)
        XCTAssertNil(cfg.baseImage)
        XCTAssertEqual(cfg.container?.baseImage, "debian:12", "the container's base image must survive")
    }

    func testTartBaseImageRejectsHazardousReferencesBeforeWriting() throws {
        let url = try file(both)
        XCTAssertThrowsError(
            try GeneralConfigEditor.setBaseImage("--privileged", for: .tart, at: url))
        XCTAssertThrowsError(try GeneralConfigEditor.setBaseImage("two words", for: .tart, at: url))
        XCTAssertNil(try ConfigLoader.load(from: url).baseImage, "a rejected edit must not write")
    }
}
