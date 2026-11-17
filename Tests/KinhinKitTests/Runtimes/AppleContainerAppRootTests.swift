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

    private static func status(appRoot: String) -> ShellResult {
        ShellResult(
            exitCode: 0, stdout: #"{"paths":{"appRoot":"\#(appRoot)","installRoot":"/x/"},"status":"running"}"#,
            stderr: "")
    }

    func testTheRunningAppRootIsReadFromTheStatus() {
        XCTAssertEqual(
            AppleContainerRuntime.runningAppRoot(statusJSON: #"{"paths":{"appRoot":"/Volumes/S/container/"}}"#),
            "/Volumes/S/container/")
        XCTAssertNil(AppleContainerRuntime.runningAppRoot(statusJSON: #"{"status":"running"}"#))
        XCTAssertNil(AppleContainerRuntime.runningAppRoot(statusJSON: "status running"))
    }

    func testAServiceRunningOnAnotherAppRootStopsTheStart() async {
        let shell = FakeShell()
        shell.responses = [Self.status(appRoot: "/Users/ci/Library/Application Support/com.apple.container/")]
        do {
            try await AppleContainerRuntime.requireRunningAppRoot("/Volumes/Storage/container", shell: shell)
            XCTFail("expected the running app root to stop the start")
        } catch let problem as StorageProblem {
            XCTAssertEqual(problem.location, .containerAppRoot)
            XCTAssertTrue(problem.problem.contains("com.apple.container"), problem.problem)
            XCTAssertTrue(problem.fix.contains("container system stop"), problem.fix)
        } catch {
            XCTFail("expected a StorageProblem, got \(error)")
        }
        XCTAssertEqual(shell.calls.first?.suffix(4), ["system", "status", "--format", "json"])
    }

    func testAServiceRunningOnTheConfiguredAppRootGoesOn() async throws {
        let shell = FakeShell()
        shell.responses = [Self.status(appRoot: "/Volumes/Storage/container/")]
        try await AppleContainerRuntime.requireRunningAppRoot("/Volumes/Storage/container", shell: shell)
        let unreadable = FakeShell()
        unreadable.responses = [ShellResult(exitCode: 0, stdout: "FIELD VALUE", stderr: "")]
        try await AppleContainerRuntime.requireRunningAppRoot("/Volumes/Storage/container", shell: unreadable)
    }

    func testSameDirectoryIgnoresATrailingSlashAndFollowsSymlinks() throws {
        XCTAssertTrue(StoragePreflight.sameDirectory("/Volumes/X/container/", "/Volumes/X/container"))
        XCTAssertFalse(StoragePreflight.sameDirectory("/Volumes/X/container", "/Volumes/Y/container"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-same-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertTrue(StoragePreflight.sameDirectory(link.path, real.path))
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
