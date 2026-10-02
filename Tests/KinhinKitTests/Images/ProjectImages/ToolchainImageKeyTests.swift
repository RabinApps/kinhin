import XCTest

@testable import KinhinKit

final class ToolchainImageKeyTests: XCTestCase {
    private func key(_ specs: [String], base: String = "tahoe-base", stacks: [String]? = nil) -> String {
        var toolchains = KinhinConfig.ToolchainsConfig()
        toolchains.specs = specs
        toolchains.stacks = stacks
        return ToolchainImageKey.make(toolchains: toolchains, base: base, platform: .macOS)
    }

    func testOrderAndCaseDoNotMatter() {
        XCTAssertEqual(key(["go@1.22.5", "node@22"]), key(["Node@22", "go@1.22.5"]))
    }

    func testVersionBaseAndStacksChangeTheKey() {
        XCTAssertNotEqual(key(["go@1.22.5"]), key(["go@1.23.4"]))
        XCTAssertNotEqual(key(["go@1.22.5"]), key(["go@1.22.5"], base: "other"))
        XCTAssertNotEqual(key(["node@22"]), key(["node@22"], stacks: ["vercel"]))
    }

    func testShapeAndName() {
        let value = key(["go@1.22.5"])
        XCTAssertEqual(value.count, 9)
        XCTAssertTrue(value.hasPrefix("p"))
        XCTAssertEqual(ToolchainImageKey.imageName(base: "tahoe-base", key: value), "tahoe-base-\(value)")
    }
}
