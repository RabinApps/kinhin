import XCTest

@testable import KinhinKit

/// `ImageBuildService.tartOptions` is the single entry point every prepare
/// path (CLI `--image`/`--all`, app buttons, setup checklist) resolves its
/// bake through, so none of them may drop a configured key.
final class ImageBuildServiceTests: XCTestCase {
    private let baseImage = "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"

    private func config(images: [KinhinConfig.ImageConfig] = []) -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.image = "kinhin-base"
        cfg.baseImage = baseImage
        cfg.provisionScript = "/tmp/provision.sh"
        cfg.images = images
        return cfg
    }

    func testPrimaryOptionsComeFromImageAndBaseImage() throws {
        let options = try ImageBuildService.tartOptions(config: config(), image: nil)
        XCTAssertEqual(options.target, "kinhin-base")
        XCTAssertEqual(options.source, baseImage)
        XCTAssertEqual(options.provisionScriptPath, "/tmp/provision.sh")
    }

    func testNamedEntryUsesItsOwnTargetAndBase() throws {
        let cfg = config(images: [
            .init(name: "xcode", baseImage: "ghcr.io/acme/macos-xcode:26", labels: ["xcode"])
        ])
        let options = try ImageBuildService.tartOptions(config: cfg, image: "xcode")
        XCTAssertEqual(options.target, "xcode")
        XCTAssertEqual(options.source, "ghcr.io/acme/macos-xcode:26")
        XCTAssertEqual(options.provisionScriptPath, "/tmp/provision.sh", "fleet keys still apply")
    }

    func testEntryNamedLikeThePrimaryResolvesToThePrimary() throws {
        // `tartOptions` short-circuits any name equal to `image:` — an entry
        // duplicating the primary cannot shadow it with different options.
        let cfg = config(images: [.init(name: "kinhin-base", baseImage: "ghcr.io/acme/other:1")])
        let options = try ImageBuildService.tartOptions(config: cfg, image: "kinhin-base")
        XCTAssertEqual(options.target, "kinhin-base")
        XCTAssertEqual(options.source, baseImage, "the primary's base_image wins over the duplicate entry")
    }

    func testUnknownImageNameThrows() {
        XCTAssertThrowsError(try ImageBuildService.tartOptions(config: config(), image: "nope")) { error in
            guard case ImageError.unknownImage(let name) = error else {
                return XCTFail("expected .unknownImage, got \\(error)")
            }
            XCTAssertEqual(name, "nope")
        }
    }

    func testEntryWithoutBaseImageKeepsTheDocumentedDefaultSource() throws {
        let cfg = config(images: [.init(name: "plain")])
        let options = try ImageBuildService.tartOptions(config: cfg, image: "plain")
        XCTAssertEqual(options.target, "plain")
        XCTAssertEqual(options.source, ImagePreparer.defaultSource)
    }
}
