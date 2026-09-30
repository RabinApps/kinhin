import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ImagePreparerTests: XCTestCase {
    func testImagePrepareHappyPath() async throws {
        let tart = FakeTart()
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        var options = ImagePreparer.Options(hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false)
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

    func testImagePrepareSkipsTheRegistryPullForALocalSourceVM() async throws {
        // A locally created VM (tart create --linux, then OS-installed) is not
        // a registry reference — pulling it would fail. Names without a slash
        // are treated as local and used as-is.
        let tart = FakeTart()
        let preparer = ImagePreparer(tart: tart, ssh: FakeSSH())
        var options = ImagePreparer.Options(hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false)
        options.source = "ubuntu-scratch"
        options.target = "ubuntu-base"

        try await preparer.run(options)

        XCTAssertTrue(tart.pullCalls.isEmpty, "a local VM is never pulled")
        XCTAssertEqual(tart.cloneCalls.first?.source, "ubuntu-scratch")
        XCTAssertEqual(tart.cloneCalls.last?.name, "ubuntu-base")
    }

    func testImagePrepareReplacesExistingTarget() async throws {
        let tart = FakeTart()
        tart.vms["tahoe-base"] = TartVM(name: "tahoe-base", source: "old-source", status: "stopped")
        let preparer = ImagePreparer(tart: tart, ssh: FakeSSH())
        var options = ImagePreparer.Options(hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false)
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
        var options = ImagePreparer.Options(hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false)
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

final class ContainerKernelRecoveryTests: XCTestCase {
    private let kernelError = ShellResult(
        exitCode: 1, stdout: "",
        stderr: "Error: default kernel not configured for architecture arm64, please use `container system kernel set`")

    func testInstallsTheRecommendedKernelAndRetriesOnce() async throws {
        let shell = FakeShell()
        // 1st call: scratch start fails for want of a kernel; then the kernel
        // install and every later call succeed.
        shell.responses = [kernelError]
        let options = LinuxImageOptions(
            image: "ubuntu:24.04", target: "out", hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false)
        let target = try await ContainerImagePreparer(shell: shell).prepare(
            options, versions: .init(github: "1", gitea: "1"))
        XCTAssertEqual(target, "out")
        let calls = shell.calls
        XCTAssertTrue(
            calls.contains { $0.suffix(4) == ["system", "kernel", "set", "--recommended"] },
            "expected a kernel install, got \(calls)")
        XCTAssertEqual(calls.filter { $0.contains("run") && $0.contains("--detach") }.count, 2, "start retried once")
    }

    func testOtherStartFailuresAreNotRetried() async {
        let shell = FakeShell()
        shell.responses = [ShellResult(exitCode: 1, stdout: "", stderr: "Error: 401 Unauthorized")]
        let options = LinuxImageOptions(
            image: "nope", target: "out", hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false)
        do {
            _ = try await ContainerImagePreparer(shell: shell).prepare(
                options, versions: .init(github: "1", gitea: "1"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401 Unauthorized"), error.localizedDescription)
        }
        XCTAssertFalse(shell.calls.contains { $0.contains("kernel") })
    }
}

final class FailureExcerptTests: XCTestCase {
    func testExcerptSkipsAptChatterAndKeepsTheRealError() {
        let stderr = """
            debconf: delaying package configuration, since apt-utils is not installed
            mise ERROR failed to install node@node@22
            mise ERROR invalid version: node@22
            """
        let excerpt = ShellResult(exitCode: 1, stdout: "", stderr: stderr).failureExcerpt
        XCTAssertFalse(excerpt.contains("debconf"))
        XCTAssertTrue(excerpt.contains("invalid version: node@22"), excerpt)
    }

    func testExcerptShowsTheTailOfALongLog() {
        let stderr = (1...50).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = ShellResult(exitCode: 1, stdout: "", stderr: stderr).failureExcerpt
        XCTAssertTrue(excerpt.hasSuffix("line 50"))
        XCTAssertFalse(excerpt.contains("line 1\n"))
    }

    func testExcerptSaysSoWhenThereIsNoUsefulOutput() {
        XCTAssertEqual(
            ShellResult(exitCode: 3, stdout: "", stderr: "").failureExcerpt, "no error output (exit 3)")
        XCTAssertEqual(
            ShellResult(exitCode: 3, stdout: "", stderr: "debconf: only noise").failureExcerpt, "exit 3")
    }
}

final class ContainerCommitTests: XCTestCase {
    private func options() -> LinuxImageOptions {
        LinuxImageOptions(
            image: "ubuntu:24.04", target: "out-image", hasGitHubToken: true, hasGiteaToken: false,
            hasGitLabToken: false)
    }

    func testCommitExportsTheScratchFilesystemThenBuildsFromScratch() async throws {
        let shell = FakeShell()
        _ = try await ContainerImagePreparer(shell: shell).prepare(options(), versions: .init(github: "1", gitea: "1"))
        let calls = shell.calls
        let export = try XCTUnwrap(calls.firstIndex { $0.contains("export") }, "\(calls)")
        let build = try XCTUnwrap(calls.firstIndex { $0.contains("build") }, "\(calls)")
        XCTAssertLessThan(export, build)
        XCTAssertTrue(calls[export].contains("--output"))
        XCTAssertEqual(calls[build].dropFirst().prefix(3), ["build", "--tag", "out-image"])
        XCTAssertFalse(calls.contains { $0.contains("FROM") }, "the Dockerfile is a file, not an argument")
    }

    func testExportFailureIsReportedWithItsReason() async {
        let shell = FakeShell()
        shell.failOn = "export"
        do {
            _ = try await ContainerImagePreparer(shell: shell).prepare(
                options(), versions: .init(github: "1", gitea: "1"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("container export failed"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("boom"), error.localizedDescription)
        }
        XCTAssertFalse(shell.calls.contains { $0.contains("build") }, "no build after a failed export")
    }
}
