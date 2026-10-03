import KinhinKit
import XCTest

@testable import kinhin

/// `kinhin image prepare` target selection: `--all` bakes every configured
/// image once, and the flags that name a single image are refused with it.
final class ImageCommandTests: XCTestCase {
    private let images: [KinhinConfig.ImageConfig] = [
        .init(name: "xcode", labels: ["xcode"]),
        .init(name: "web", labels: ["node"]),
    ]

    func testAllSelectsThePrimaryThenEveryNamedEntry() throws {
        XCTAssertEqual(try ImageCommand.bakeTargets(args: ["--all"], images: images), [nil, "xcode", "web"])
    }

    func testBareAndImageSelectOne() throws {
        XCTAssertEqual(try ImageCommand.bakeTargets(args: [], images: images), [nil])
        XCTAssertEqual(try ImageCommand.bakeTargets(args: ["--image", "xcode"], images: images), ["xcode"])
    }

    func testSourceAndTargetNameOneImageSoTheyAreRefusedWithAll() {
        for flag in ["--source", "--target"] {
            XCTAssertThrowsError(try ImageCommand.bakeTargets(args: ["--all", flag, "vm"], images: images)) { error in
                guard let cliError = error as? CLIError else { return XCTFail("expected CLIError, got \\(error)") }
                XCTAssertEqual(cliError.exit, .usage)
                XCTAssertTrue(cliError.message.contains(flag), cliError.message)
            }
        }
        // On a single bake the overrides are fine.
        XCTAssertNoThrow(try ImageCommand.bakeTargets(args: ["--target", "vm"], images: images))
        XCTAssertNoThrow(try ImageCommand.bakeTargets(args: ["--image", "xcode", "--source", "vm"], images: images))
    }

    func testRunnerVersionAppliesToTheWholeAll() throws {
        // A fleet-wide agent pin is meaningful for every image: allowed.
        XCTAssertNoThrow(try ImageCommand.bakeTargets(args: ["--all", "--runner-version", "1.2.3"], images: images))
    }
}
