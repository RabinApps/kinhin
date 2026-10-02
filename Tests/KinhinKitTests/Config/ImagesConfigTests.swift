import XCTest

@testable import KinhinKit

final class ImagesConfigTests: XCTestCase {
    private static let head = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [self-hosted]
        """

    private func file(_ yaml: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imgcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Loader

    func testAbsentImagesIsEmpty() throws {
        XCTAssertEqual(try ConfigLoader.parse(Self.head).images, [])
    }

    func testParsesNamedImages() throws {
        let cfg = try ConfigLoader.parse(
            """
            \(Self.head)
            images:
              - name: xcode
                base_image: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"
                labels: [xcode]
              - name: plain
            """)
        XCTAssertEqual(
            cfg.images,
            [
                .init(name: "xcode", baseImage: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest", labels: ["xcode"]),
                .init(name: "plain"),
            ])
    }

    func testRejectsBadNames() {
        func parse(_ entry: String) throws { _ = try ConfigLoader.parse("\(Self.head)\nimages:\n\(entry)\n") }
        XCTAssertThrowsError(try parse("  - base_image: x/y"), "name is required")
        XCTAssertThrowsError(try parse("  - name: \"-rf\""))
        XCTAssertThrowsError(try parse("  - name: \"two words\""))
        XCTAssertThrowsError(try parse("  - name: kinhin-xcode"), "reserved: recovery and cleanup delete these")
        XCTAssertThrowsError(try parse("  - name: orchard-x"))
        XCTAssertThrowsError(try parse("  - name: tahoe-base"), "same as image:")
        XCTAssertThrowsError(try parse("  - name: a\n  - name: a"), "duplicate")
        XCTAssertThrowsError(try parse("  - name: a\n    base_image: \"--privileged\""))
        XCTAssertThrowsError(try parse("  - name: a\n    labels: [\"\"]"))
    }

    // MARK: - Editor

    func testEditorAddsReplacesAndRemovesKeepingComments() throws {
        let url = try file("\(Self.head)\n# keep me\nmax_runners: 2\n")
        let xcode = KinhinConfig.ImageConfig(name: "xcode", baseImage: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest")
        try ImagesConfigEditor.apply([xcode], to: url)
        XCTAssertEqual(try ConfigLoader.load(from: url).images, [xcode])
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("# keep me"))

        let two = [xcode, .init(name: "plain", labels: ["a", "b"])]
        try ImagesConfigEditor.apply(two, to: url)
        XCTAssertEqual(try ConfigLoader.load(from: url).images, two)
        XCTAssertEqual(try ConfigStore.snapshot(at: url)?.images, two)

        try ImagesConfigEditor.apply([], to: url)
        XCTAssertEqual(try ConfigLoader.load(from: url).images, [])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("images:"))
        XCTAssertTrue(text.contains("max_runners: 2"), "keys after the section survive removal")
    }

    func testEditorRefusesAnInvalidNameWithoutWriting() throws {
        let url = try file(Self.head + "\n")
        let before = try String(contentsOf: url, encoding: .utf8)
        XCTAssertThrowsError(try ImagesConfigEditor.apply([.init(name: "kinhin-x")], to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before)
    }

    // MARK: - Prepare options

    func testPrepareOptionsPickTheNamedImage() throws {
        var cfg = KinhinConfig.default
        cfg.image = "main"
        cfg.baseImage = "ghcr.io/cirruslabs/macos-sequoia-base:latest"
        cfg.images = [.init(name: "xcode", baseImage: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest")]

        let primary = try ImageBuildService.tartOptions(config: cfg, image: nil)
        XCTAssertEqual(primary.target, "main", "a prepare targets image:, not always tahoe-base")
        XCTAssertEqual(primary.source, "ghcr.io/cirruslabs/macos-sequoia-base:latest")
        XCTAssertEqual(try ImageBuildService.tartOptions(config: cfg, image: "main").target, "main")

        let xcode = try ImageBuildService.tartOptions(config: cfg, image: "xcode")
        XCTAssertEqual(xcode.target, "xcode")
        XCTAssertEqual(xcode.source, "ghcr.io/cirruslabs/macos-tahoe-xcode:latest")

        XCTAssertThrowsError(try ImageBuildService.tartOptions(config: cfg, image: "nope"))
    }
}
