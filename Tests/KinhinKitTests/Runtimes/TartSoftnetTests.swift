import XCTest

@testable import KinhinKit

final class TartSoftnetTests: XCTestCase {
    func testSoftnetFlagIsAddedOnlyWhenRequested() {
        XCTAssertEqual(
            TartController.runArguments(name: "vm", mounts: [], softnet: false), ["run", "--no-graphics", "vm"])
        XCTAssertEqual(
            TartController.runArguments(name: "vm", mounts: [], softnet: true),
            ["run", "--no-graphics", "--net-softnet", "vm"])
    }

    func testMountsStillPrecedeTheVMName() {
        XCTAssertEqual(
            TartController.runArguments(name: "vm", mounts: ["/cache"], softnet: true),
            ["run", "--no-graphics", "--net-softnet", "--virtiofs", "/cache", "vm"])
    }

    func testConfigKeyParses() throws {
        let on = try ConfigLoader.parse("tart_softnet: true\n")
        XCTAssertEqual(on.tartSoftnet, true)
        XCTAssertNil(try ConfigLoader.parse("labels: [macos]\n").tartSoftnet, "off unless asked for")
    }
}
