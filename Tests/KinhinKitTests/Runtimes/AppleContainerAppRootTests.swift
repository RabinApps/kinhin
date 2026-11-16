import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `container_app_root:`: every `container system start` carries `--app-root` after the volume passed its preflight,
/// and kernels are looked for under that root.
final class AppleContainerAppRootTests: XCTestCase {
    func testTheStartArgvCarriesTheAppRootWhenOneIsConfigured() {
        XCTAssertEqual(
            AppleContainerRuntime.startArguments(binary: "/bin/container", appRoot: "/Volumes/Storage/container"),
            [
                "/bin/container", "system", "start", "--app-root", "/Volumes/Storage/container",
                "--enable-kernel-install",
            ])
        XCTAssertEqual(
            AppleContainerRuntime.startArguments(binary: "/bin/container", appRoot: nil),
            ["/bin/container", "system", "start", "--enable-kernel-install"])
    }

    func testKernelsLiveUnderTheConfiguredAppRoot() {
        XCTAssertEqual(
            AppleContainerRuntime.kernels(underAppRoot: "/Volumes/Storage/container").path,
            "/Volumes/Storage/container/kernels")
        XCTAssertTrue(
            AppleContainerRuntime.kernels(underAppRoot: nil).path.hasSuffix(
                "Application Support/com.apple.container/kernels"))
    }

    func testAnAppRootOnAnUnmountedVolumeStartsNothing() async {
        let shell = FakeShell()
        let unmounted = StoragePreflight(
            volume: { _ in StoragePreflight.Volume(mountPoint: "/", ignoresOwnership: false) },
            entry: { _ in .missing })
        do {
            try await AppleContainerRuntime.startSystem(
                shell: shell, appRoot: "/Volumes/Storage/container", preflight: unmounted)
            XCTFail("expected the preflight to stop the start")
        } catch let problem as StorageProblem {
            XCTAssertEqual(problem.location, .containerAppRoot)
            XCTAssertEqual(problem.problem, "the volume /Volumes/Storage is not mounted")
        } catch {
            XCTFail("expected a StorageProblem, got \(error)")
        }
        XCTAssertEqual(shell.calls, [], "no `container system start` without the configured app root")
    }

    func testAnAppRootWithOwnershipDisabledStartsNothing() async {
        let shell = FakeShell()
        let ignored = StoragePreflight(
            volume: { _ in StoragePreflight.Volume(mountPoint: "/Volumes/Storage", ignoresOwnership: true) },
            entry: { _ in .directory })
        do {
            try await AppleContainerRuntime.startSystem(
                shell: shell, appRoot: "/Volumes/Storage/container", preflight: ignored)
            XCTFail("expected the preflight to stop the start")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("sudo diskutil enableOwnership /Volumes/Storage"))
        }
        XCTAssertEqual(shell.calls, [])
    }
}
