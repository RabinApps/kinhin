import XCTest

@testable import KinhinKit
@testable import kinhin

// `image prepare --source <vm>` is the second half of the documented Tart Linux recipe, and `--target` names the
// result. Both were parsed by no one, so the bake silently started from the default macOS image (e2e Tart lanes).
final class ImagePrepareSourceTargetTests: XCTestCase {
    func testSourceAndTargetReachTheTartBake() throws {
        var options = ImagePreparer.Options(target: "kinhin-base")
        try ImageCommand.applySourceAndTarget(
            ["prepare", "--source", "my-linux-vm", "--target", "my-linux-runner"], to: &options)
        XCTAssertEqual(options.source, "my-linux-vm")
        XCTAssertEqual(options.target, "my-linux-runner")
    }

    func testWithoutTheFlagsTheConfigDecides() throws {
        var options = ImagePreparer.Options(target: "kinhin-base")
        let source = options.source
        try ImageCommand.applySourceAndTarget(["prepare"], to: &options)
        XCTAssertEqual(options.source, source)
        XCTAssertEqual(options.target, "kinhin-base")
    }

    func testAnOptionLikeSourceIsRefused() {
        var options = ImagePreparer.Options(target: "kinhin-base")
        XCTAssertThrowsError(try ImageCommand.applySourceAndTarget(["prepare", "--source", "-rf"], to: &options))
    }
}
