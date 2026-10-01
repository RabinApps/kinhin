import XCTest

@testable import KinhinKit

/// The shared toolchain cache in tart Linux guests: macOS guests auto-mount
/// virtiofs shares, Linux guests need an explicit mount and a symlink.
final class TartLinuxCacheMountTests: XCTestCase {
    func testMountScriptMountsTheAutomountTagAndLinksTheCache() {
        let script = RunnerBootstrap.tartLinuxCacheMountScript()
        XCTAssertTrue(script.contains("mount -t virtiofs com.apple.virtio-fs.automount /mnt/shared"), script)
        XCTAssertTrue(script.contains("ln -s /mnt/shared/kinhin-cache /var/kinhin-cache"), script)
        XCTAssertTrue(script.contains("mountpoint -q"), "re-runs must not mount twice")
        XCTAssertTrue(script.contains("sudo -n true"), "the admin user elevates through passwordless sudo")
    }

    func testMountFailureIsBestEffort() {
        XCTAssertTrue(
            RunnerBootstrap.tartLinuxCacheMountScript().contains("continuing without the shared toolchain cache"))
    }

    func testMountScriptIsValidShell() throws {
        for (label, script) in [
            ("mount", RunnerBootstrap.tartLinuxCacheMountScript()),
            ("prepare (linux)", GuestOS.linux.prepareScript()),
            ("prefix", Self.prefix()),
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-n", "-c", script]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(label) must be valid bash: \(script)")
        }
    }

    func testLinuxPrepareScriptMountsTheCache() {
        XCTAssertTrue(GuestOS.linux.prepareScript().contains("mount -t virtiofs"))
        XCTAssertFalse(GuestOS.macOS.prepareScript().contains("mount -t virtiofs"))
    }

    // MARK: - Runner VM prefix

    func testTartCachePrefixPicksTheCacheRootPerGuest() {
        let prefix = Self.prefix()
        XCTAssertTrue(prefix.contains("[ \"$(uname -s)\" = \"Linux\" ]"), prefix)
        XCTAssertTrue(prefix.contains("KINHIN_CACHE_ROOT=/var/kinhin-cache"), prefix)
        XCTAssertTrue(prefix.contains("KINHIN_CACHE_ROOT=\"/Volumes/My Shared Files/kinhin-cache\""), prefix)
        XCTAssertTrue(prefix.contains("export CARGO_HOME=\"$KINHIN_CACHE_ROOT/cargo\""), prefix)
    }

    func testTartCachePrefixIsEmptyWithoutAMountOrSelection() {
        XCTAssertEqual(RunnerBootstrap.tartCachePrefix(mounted: false, selection: Self.selection()), "")
        XCTAssertEqual(RunnerBootstrap.tartCachePrefix(mounted: true, selection: nil), "")
    }

    /// Run on the host (Darwin) the prefix must take the macOS branch and not
    /// touch the Linux paths.
    func testTartCachePrefixResolvesOnTheHost() async throws {
        #if os(macOS)
            let result = try await Shell().run([
                "/bin/bash", "-c", Self.prefix() + "\nprintf '%s' \"$KINHIN_CACHE_ROOT\"",
            ])
            XCTAssertEqual(result.stdout, ToolchainCacheMount.guestPath)
        #endif
    }

    private static func selection() -> ManagedToolchainSelection {
        var selection = ManagedToolchainSelection()
        selection.cacheEnvs = [ToolchainCacheEnv(variable: "CARGO_HOME", subdirectory: "cargo")]
        return selection
    }

    private static func prefix() -> String {
        RunnerBootstrap.tartCachePrefix(mounted: true, selection: selection())
    }
}
