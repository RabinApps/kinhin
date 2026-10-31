import XCTest

@testable import KinhinKit

/// `min_idle` (idle registered runners per pool and per Tart image): parsing, defaults, the bounds the loader
/// enforces, and the editors that rewrite whole sections keeping it.
final class MinIdleConfigTests: XCTestCase {
    private static let head = """
        accounts:
          - name: github
            forge: github
            scope: "acme"
        labels: [self-hosted, arm64]
        """

    private func invalidMessage(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try ConfigLoader.parse(yaml)
            XCTFail("expected a ConfigError", file: file, line: line)
            return ""
        } catch ConfigError.invalid(let why) {
            return why
        } catch {
            XCTFail("expected ConfigError.invalid, got \(error)", file: file, line: line)
            return ""
        }
    }

    // MARK: - Parsing

    func testDefaultsToOffEverywhere() throws {
        let cfg = try ConfigLoader.parse(
            "\(Self.head)\nimages:\n  - name: xcode\n    labels: [xcode]\n"
                + "container:\n  image: kinhin-ci-linux\ndocker:\n  image: kinhin-ci-linux\n")
        XCTAssertEqual(cfg.imageMinIdle, 0)
        XCTAssertEqual(cfg.images.first?.minIdle, 0)
        XCTAssertEqual(cfg.container?.minIdle, 0)
        XCTAssertEqual(cfg.docker?.minIdle, 0)
    }

    func testParsesEveryKey() throws {
        let cfg = try ConfigLoader.parse(
            """
            \(Self.head)
            max_runners: 10
            image_min_idle: 1
            images:
              - name: macos-27
                labels: [macos]
                min_idle: 1
            container:
              image: kinhin-ci-linux
              min_idle: 2
            docker:
              image: kinhin-ci-linux
              min_idle: 3
            """)
        XCTAssertEqual(cfg.imageMinIdle, 1)
        XCTAssertEqual(cfg.images.first?.minIdle, 1)
        XCTAssertEqual(cfg.container?.minIdle, 2)
        XCTAssertEqual(cfg.docker?.minIdle, 3)
    }

    func testTheKeysAreKnownToTheSchema() throws {
        let yaml = """
            image_min_idle: 1
            images:
              - name: xcode
                min_idle: 1
            container:
              min_idle: 1
            docker:
              min_idle: 1
            """
        XCTAssertEqual(try ConfigSchema.unknownKeys(in: yaml), [])
    }

    func testTheStarterTemplateStillParses() throws {
        XCTAssertEqual(try ConfigLoader.parse(ConfigLoader.template()).imageMinIdle, 0)
    }

    func testTheSynthesizedDefaultImageEntryCarriesNoFloor() throws {
        // image_labels synthesizes an images-style entry for `image:`; its floor stays the top-level key.
        let cfg = try ConfigLoader.parse("\(Self.head)\nimage_labels: [mac]\nimage_min_idle: 1\n")
        XCTAssertEqual(cfg.effectiveImages().first { $0.name == cfg.image }?.minIdle, 0)
        XCTAssertEqual(cfg.imageMinIdle, 1)
    }

    // MARK: - Validation

    func testNegativeValuesAreRejected() {
        XCTAssertTrue(invalidMessage("\(Self.head)\nimage_min_idle: -1\n").contains("image_min_idle"))
        XCTAssertTrue(
            invalidMessage("\(Self.head)\nimages:\n  - name: xcode\n    min_idle: -1\n").contains("images[0].min_idle"))
        XCTAssertTrue(
            invalidMessage("\(Self.head)\ncontainer:\n  image: kinhin-ci-linux\n  min_idle: -1\n")
                .contains("container.min_idle"))
        XCTAssertTrue(
            invalidMessage("\(Self.head)\ndocker:\n  image: kinhin-ci-linux\n  min_idle: -1\n")
                .contains("docker.min_idle"))
    }

    func testAnImageFloorPlusItsWarmPoolMustFitMaxRunners() {
        let why = invalidMessage(
            "\(Self.head)\nmax_runners: 2\nimages:\n  - name: xcode\n    warm_pool: 1\n    min_idle: 2\n")
        XCTAssertTrue(why.contains("images: xcode min_idle"), why)
        let base = invalidMessage("\(Self.head)\nmax_runners: 2\nwarm_pool: 1\nimage_min_idle: 2\n")
        XCTAssertTrue(base.contains("image_min_idle"), base)
    }

    func testAPoolFloorMustFitMaxRunners() {
        let container = invalidMessage(
            "\(Self.head)\nmax_runners: 2\ncontainer:\n  image: kinhin-ci-linux\n  min_idle: 3\n")
        XCTAssertTrue(container.contains("container.min_idle"), container)
        let docker = invalidMessage(
            "\(Self.head)\nmax_runners: 10\ndocker:\n  image: kinhin-ci-linux\n  max_slots: 2\n  min_idle: 3\n")
        XCTAssertTrue(docker.contains("docker.max_slots"), docker)
    }

    func testAllFloorsTogetherMustFitMaxRunners() {
        let why = invalidMessage(
            "\(Self.head)\nmax_runners: 3\nimage_min_idle: 1\n"
                + "images:\n  - name: xcode\n    labels: [xcode]\n    min_idle: 1\n"
                + "container:\n  image: kinhin-ci-linux\n  min_idle: 2\n")
        XCTAssertTrue(why.contains("min_idle across"), why)
    }

    func testHugeFloorsAreRejectedRatherThanOverflowing() {
        let huge = Int.max
        let base = invalidMessage("\(Self.head)\nmax_runners: \(huge)\nwarm_pool: 1\nimage_min_idle: \(huge)\n")
        XCTAssertTrue(base.contains("image_min_idle"), base)
        let image = invalidMessage(
            "\(Self.head)\nmax_runners: \(huge)\nimages:\n  - name: xcode\n    warm_pool: 1\n    min_idle: \(huge)\n")
        XCTAssertTrue(image.contains("images: xcode min_idle"), image)
        let total = invalidMessage(
            "\(Self.head)\nmax_runners: \(huge)\nimage_min_idle: \(huge)\n"
                + "container:\n  image: kinhin-ci-linux\n  min_idle: \(huge)\n")
        XCTAssertTrue(total.contains("min_idle across"), total)
    }

    func testMacOSImageFloorsMustFitTwoMacOSVMs() {
        let why = invalidMessage(
            "\(Self.head)\nmax_runners: 10\nimage_min_idle: 1\n"
                + "images:\n  - name: macos-27\n    labels: [macos]\n    min_idle: 1\n"
                + "  - name: xcode\n    labels: [xcode]\n    min_idle: 1\n")
        XCTAssertTrue(why.contains("at most 2 macOS VMs"), why)
    }

    func testLinuxTartImagesAreNotBoundByTheMacOSLimit() throws {
        let cfg = try ConfigLoader.parse(
            "\(Self.head)\nmax_runners: 10\n"
                + "images:\n  - name: macos-27\n    labels: [macos]\n    min_idle: 2\n"
                + "  - name: linux\n    base_image: \"\(TartBaseImage.defaultLinuxReference)\"\n"
                + "    labels: [linux]\n    min_idle: 2\n")
        XCTAssertEqual(cfg.images.map(\.minIdle), [2, 2])
    }

    // MARK: - Editors keep it

    private func file(_ yaml: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minidle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testImagesEditorRoundTripsMinIdle() throws {
        let url = try file("\(Self.head)\nmax_runners: 4\n")
        let xcode = KinhinConfig.ImageConfig(name: "xcode", labels: ["xcode"], warmPool: 1, minIdle: 1)
        try ImagesConfigEditor.apply([xcode], to: url)
        XCTAssertEqual(try ConfigLoader.load(from: url).images, [xcode])
        XCTAssertEqual(try ImagesConfigEditor.parsed(from: String(contentsOf: url, encoding: .utf8)), [xcode])
        // The app edits the list it reads from the snapshot, so the snapshot must carry the floor too.
        XCTAssertEqual(try ConfigStore.snapshot(at: url)?.images, [xcode])
    }

    func testContainerAndDockerSectionRewritesKeepMinIdle() throws {
        let url = try file(
            "\(Self.head)\nmax_runners: 4\ncontainer:\n  image: kinhin-ci-linux\n  min_idle: 1\n"
                + "docker:\n  image: kinhin-ci-linux\n  min_idle: 2\n")
        _ = try GeneralConfigEditor.setBaseImage("ubuntu:24.04", for: .appleContainer, at: url)
        _ = try GeneralConfigEditor.setBaseImage("ubuntu:24.04", for: .docker, at: url)
        let cfg = try ConfigLoader.load(from: url)
        XCTAssertEqual(cfg.container?.minIdle, 1)
        XCTAssertEqual(cfg.docker?.minIdle, 2)
    }
}
