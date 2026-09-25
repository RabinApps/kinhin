import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ImagePreparerTests: XCTestCase {
    func testImagePrepareHappyPath() async throws {
        let tart = FakeTart()
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        var options = ImagePreparer.Options(hasGitHubToken: true, hasGiteaToken: false)
        options.source = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
        options.target = "tahoe-base"

        try await preparer.run(options)

        XCTAssertEqual(tart.pullCalls, ["ghcr.io/cirruslabs/macos-tahoe-base:latest"])
        // First clone: source -> scratch; last clone: scratch -> target.
        XCTAssertEqual(tart.cloneCalls.first?.source, options.source)
        XCTAssertEqual(tart.cloneCalls.last?.name, options.target)
        let scratch = try XCTUnwrap(tart.cloneCalls.first?.name)
        XCTAssertNotEqual(scratch, options.target, "scratch VM must differ from the target")
        // The final clone sources from the scratch VM.
        XCTAssertEqual(tart.cloneCalls.last?.source, scratch)
        XCTAssertEqual(tart.vms[options.target]?.source, scratch)
    }

    func testImagePrepareReplacesExistingTarget() async throws {
        let tart = FakeTart()
        tart.vms["tahoe-base"] = TartVM(name: "tahoe-base", source: "old-source", status: "stopped")
        let preparer = ImagePreparer(tart: tart, ssh: FakeSSH())
        var options = ImagePreparer.Options(hasGitHubToken: true, hasGiteaToken: false)
        options.target = "tahoe-base"

        try await preparer.run(options)

        XCTAssertTrue(tart.deleteCalls.contains("tahoe-base"), "old image is deleted before the new one lands")
        // The final clone targeted the same name and sourced from the scratch VM.
        XCTAssertEqual(tart.cloneCalls.last?.name, "tahoe-base")
        let scratch = try XCTUnwrap(tart.cloneCalls.first?.name)
        XCTAssertEqual(tart.vms["tahoe-base"]?.source, scratch, "target now sources from the fresh scratch clone")
    }

    func testImagePrepareProvisioningFailureLeavesTargetUntouched() async throws {
        let tart = FakeTart()
        let ssh = FakeSSH()
        ssh.failWith = "sudo: a password is required"
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        var options = ImagePreparer.Options(hasGitHubToken: true, hasGiteaToken: false)
        options.target = "tahoe-base"

        do {
            try await preparer.run(options)
            XCTFail("expected provisioning failure")
        } catch let error as ImageError {
            guard case .provisioningFailed(let why) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(why.contains("password"))
        }
        // The target must NOT have been created from the failed scratch VM.
        XCTAssertNil(tart.vms["tahoe-base"])
        XCTAssertFalse(tart.deleteCalls.contains("tahoe-base"))
        XCTAssertFalse(tart.cloneCalls.contains { $0.name == "tahoe-base" })
    }
}

final class LinuxImageBakerTests: XCTestCase {
    private func options() -> LinuxImageOptions {
        LinuxImageOptions(image: "missing-base", target: "out", hasGitHubToken: true, hasGiteaToken: false)
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
