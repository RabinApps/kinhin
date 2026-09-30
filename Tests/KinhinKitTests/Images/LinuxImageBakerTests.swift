import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class LinuxImageBakerTests: XCTestCase {
    private func options() -> LinuxImageOptions {
        LinuxImageOptions(
            image: "missing-base", target: "out", hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false)
    }

    func testFailsImmediatelyWithTheCLIsReasonWhenTheScratchContainerWontStart() async {
        let shell = FakeShell()
        shell.failOn = "run"
        shell.defaultResult = ShellResult(exitCode: 0, stdout: "", stderr: "")
        let started = Date()
        do {
            _ = try await ContainerImagePreparer(shell: shell).prepare(
                options(), versions: .init(github: "1", gitea: "1"))
            XCTFail("expected the bake to fail")
        } catch let error as ImageError {
            guard case .containerProvisioningFailed(let why) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertTrue(why.contains("could not start a container from 'missing-base'"), why)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "must not poll exec for the full readiness timeout")
        XCTAssertFalse(shell.calls.contains { $0.contains("exec") }, "never got as far as exec")
    }

    func testBaseImageIsTheConfiguredOneOnlyWhenItExistsLocally() {
        XCTAssertEqual(
            LinuxImageOptions.baseImage(configured: "kinhin-ci-linux", localImages: ["kinhin-ci-linux:latest"]),
            "kinhin-ci-linux")
        XCTAssertEqual(
            LinuxImageOptions.baseImage(configured: "kinhin-ci-linux", localImages: ["kinhin-ci-linux"]),
            "kinhin-ci-linux")
        XCTAssertEqual(
            LinuxImageOptions.baseImage(
                configured: "kinhin-ci-linux", localImages: ["ubuntu:24.04", "kinhin-ci-linux-2"]),
            "ubuntu:24.04", "a first bake has no local image to start from")
        XCTAssertEqual(
            LinuxImageOptions.baseImage(configured: "x", localImages: [], fallback: "debian:12"), "debian:12")
    }
}
