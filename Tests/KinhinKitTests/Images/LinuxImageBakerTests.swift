import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class LinuxImageBakerTests: XCTestCase {
    private func options() -> LinuxImageOptions {
        LinuxImageOptions(
            image: "missing-base", target: "out", hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false,
            hasBuildkiteToken: false, hasAzureDevOpsToken: false)
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

    func testBakeInstallsGitAndJqBeforeAnyAgentInstall() async throws {
        // CI jobs baked on this image (docs lint's `git ls-files`, checkout,
        // jq in workflow scripts) need git and jq; no agent download does, so
        // the common block must lead the composed script.
        let shell = FakeShell()
        let opts = LinuxImageOptions(
            image: "ubuntu:24.04", target: "out", hasGitHubToken: true, hasGiteaToken: false,
            hasGitLabToken: false, hasBuildkiteToken: false, hasAzureDevOpsToken: false,
            hasBitbucketToken: false)
        _ = try await ContainerImagePreparer(shell: shell).prepare(opts, versions: .init(github: "1", gitea: "1"))

        let install = try XCTUnwrap(shell.calls.first { $0.contains("-lc") }, "\(shell.calls)")
        let script = try XCTUnwrap(install.last, "\(install)")
        XCTAssertTrue(script.hasPrefix("set -euo pipefail"), "the common block runs with errexit")
        XCTAssertTrue(script.contains("command -v git"), "git must be checked for")
        XCTAssertTrue(script.contains("command -v jq"), "jq must be checked for")
        let common = try XCTUnwrap(script.range(of: "command -v git"), "no git prerequisite")
        let agent = try XCTUnwrap(script.range(of: "mkdir -p /opt/actions-runner"), "no GitHub agent install")
        XCTAssertLessThan(common.upperBound, agent.lowerBound, "git installs before the agent does")

        let syntax = try await Shell().run(["/bin/bash", "-n", "-c", script], cwd: nil, timeout: 10)
        XCTAssertTrue(syntax.succeeded, "composed bake script: \(syntax.stderr)")
    }
}
