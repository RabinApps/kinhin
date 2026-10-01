import XCTest

@testable import KinhinKit

/// The `uname -s` guest-OS detection that routes the image bake between the
/// macOS and Linux agent sets.
final class GuestOSTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(GuestOS.parse(unameOutput: "Darwin\n"), .macOS)
        XCTAssertEqual(GuestOS.parse(unameOutput: " Darwin "), .macOS)
        XCTAssertEqual(GuestOS.parse(unameOutput: "Linux\n"), .linux)
        XCTAssertEqual(GuestOS.parse(unameOutput: "linux"), .linux)
        XCTAssertNil(GuestOS.parse(unameOutput: "FreeBSD"))
        XCTAssertNil(GuestOS.parse(unameOutput: ""))
    }

    func testToolchainPlatformFollowsTheGuest() {
        XCTAssertEqual(GuestOS.macOS.toolchainPlatform, .macOS)
        XCTAssertEqual(GuestOS.linux.toolchainPlatform, .linux)
    }

    func testToolchainMountPathFollowsTheGuest() {
        XCTAssertEqual(
            GuestOS.macOS.toolchainMountPath, ToolchainCacheMount.guestPath, "macOS guests see the virtiofs share")
        XCTAssertEqual(GuestOS.linux.toolchainMountPath, ToolchainCacheMount.linuxGuestPath)
    }

    func testLinuxPrepareScriptSkipsTheMacTweaks() {
        let script = GuestOS.linux.prepareScript()
        XCTAssertFalse(script.contains("pmset"), "Linux guests have no power management to defeat")
        XCTAssertFalse(script.contains("systemsetup"), "Remote Login is the base image's own SSH setup")
        XCTAssertTrue(script.contains("set -euo pipefail"))
    }

    func testMacPrepareScriptKeepsTheClassicTweaks() {
        let script = GuestOS.macOS.prepareScript()
        XCTAssertTrue(script.contains("pmset"))
        XCTAssertTrue(script.contains("systemsetup"))
    }
}
