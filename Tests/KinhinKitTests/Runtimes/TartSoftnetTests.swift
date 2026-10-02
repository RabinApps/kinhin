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
            TartController.runArguments(name: "vm", mounts: ["kinhin-cache:/cache"], softnet: true),
            ["run", "--no-graphics", "--net-softnet", "--dir", "kinhin-cache:/cache", "vm"])
    }

    func testConfigKeyParses() throws {
        let on = try ConfigLoader.parse("tart_softnet: true\n")
        XCTAssertEqual(on.tartSoftnet, true)
        XCTAssertNil(try ConfigLoader.parse("labels: [macos]\n").tartSoftnet, "off unless asked for")
    }
}

final class TartCacheShareSpecTests: XCTestCase {
    func testShareSpecNamesTheGuestDirectoryAndPointsAtTheHostCache() {
        let spec = ToolchainCacheMount.tartDirectorySpec
        // name:hostpath → tart mounts it at "/Volumes/My Shared Files/<name>", which is guestPath.
        XCTAssertEqual(spec, "kinhin-cache:" + Paths.toolchainCache.path)
        XCTAssertTrue(ToolchainCacheMount.guestPath.hasSuffix("/" + spec.split(separator: ":")[0]))
    }
}

final class TartRunEnvironmentTests: XCTestCase {
    func testSoftnetAddsHomebrewToAGuiMinimalPath() {
        let env = TartController.runEnvironment(base: ["PATH": "/usr/bin:/bin"], softnet: true)
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertTrue(dirs.starts(with: ["/usr/bin", "/bin"]))
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"))
    }

    func testWithoutSoftnetTheEnvironmentIsUntouched() {
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/h"]
        XCTAssertEqual(TartController.runEnvironment(base: base, softnet: false), base)
    }
}
