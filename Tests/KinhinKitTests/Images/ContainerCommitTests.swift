import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ContainerCommitTests: XCTestCase {
    private let versions = RunnerVersionResolver.Versions(github: "1", gitea: "1")

    private func options(image: String = "ubuntu:24.04", platform: LinuxPlatform = .arm64) -> LinuxImageOptions {
        LinuxImageOptions(image: image, target: "out-image", storedTokens: [.github], platform: platform)
    }

    func testBuildsLayersOnTheBaseImageWithoutExportingOrRunningAScratchContainer() async throws {
        let shell = BuildContextCapturingShell()
        _ = try await ContainerImagePreparer(shell: shell).prepare(options(), versions: versions)

        let calls = shell.inner.calls
        XCTAssertEqual(calls.count, 1, "one `container build` and nothing else: \(calls)")
        let build = try XCTUnwrap(shell.builds.first)
        XCTAssertEqual(build.argv.dropFirst().prefix(3), ["build", "--tag", "out-image"])
        XCTAssertFalse(calls.contains { $0.contains("export") || $0.contains("run") || $0.contains("exec") })
        XCTAssertTrue(build.dockerfile.hasPrefix("FROM ubuntu:24.04\n"), build.dockerfile)
        XCTAssertFalse(build.dockerfile.contains("scratch"), build.dockerfile)
        XCTAssertFalse(build.dockerfile.contains("rootfs.tar"), build.dockerfile)
    }

    func testDockerfileResetsTheBaseUserAndEntrypointAndChecksForApt() async throws {
        let shell = BuildContextCapturingShell()
        _ = try await ContainerImagePreparer(shell: shell).prepare(options(), versions: versions)
        let lines = try XCTUnwrap(shell.builds.first).dockerfile.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[1], "USER root")
        XCTAssertEqual(lines[2], "ENTRYPOINT []")
        XCTAssertTrue(lines[3].hasPrefix("RUN command -v apt-get"), lines[3])
        XCTAssertTrue(lines[4].contains("/kinhin-bake/install.sh"), lines[4])
        XCTAssertEqual(lines.count, 5, "no toolchains step unless toolchains are configured")
    }

    func testInstallScriptCarriesTheAgentsAndTheHelper() async throws {
        let shell = BuildContextCapturingShell()
        _ = try await ContainerImagePreparer(shell: shell).prepare(options(), versions: versions)
        let script = try XCTUnwrap(shell.builds.first?.scripts["install.sh"])
        XCTAssertTrue(script.hasPrefix("set -euo pipefail"))
        XCTAssertTrue(script.contains("mkdir -p /opt/actions-runner"), "GitHub agent install")
        XCTAssertTrue(script.contains("| tee \(RunnerBootstrap.toolchainHelperPath)"), "toolchain helper")
        let syntax = try await Shell().run(["/bin/bash", "-n", "-c", script], cwd: nil, timeout: 10)
        XCTAssertTrue(syntax.succeeded, syntax.stderr)
    }

    func testToolchainsAreASeparateLayerAfterTheInstall() async throws {
        let shell = BuildContextCapturingShell()
        var opts = options()
        opts.toolchains = KinhinConfig.ToolchainsConfig(specs: ["node@22"])
        _ = try await ContainerImagePreparer(shell: shell).prepare(opts, versions: versions)
        let build = try XCTUnwrap(shell.builds.first)
        let installIdx = try XCTUnwrap(build.dockerfile.range(of: "install.sh"))
        let toolchainsIdx = try XCTUnwrap(build.dockerfile.range(of: "toolchains.sh"))
        XCTAssertLessThan(installIdx.lowerBound, toolchainsIdx.lowerBound)
        XCTAssertTrue(try XCTUnwrap(build.scripts["toolchains.sh"]).contains("mise use --global 'node@22'"))
    }

    func testPlatformIsPassedToTheBuild() async throws {
        let shell = BuildContextCapturingShell()
        _ = try await ContainerImagePreparer(shell: shell).prepare(options(platform: .amd64), versions: versions)
        let build = try XCTUnwrap(shell.builds.first)
        XCTAssertTrue(build.argv.contains("--platform"), "\(build.argv)")
        XCTAssertTrue(build.argv.contains("linux/amd64"), "\(build.argv)")
    }

    func testNativeBuildHasNoPlatformFlag() async throws {
        let shell = BuildContextCapturingShell()
        _ = try await ContainerImagePreparer(shell: shell).prepare(options(), versions: versions)
        XCTAssertFalse(try XCTUnwrap(shell.builds.first).argv.contains("--platform"))
    }

    func testBuildContextIsRemovedAfterwards() async throws {
        let shell = BuildContextCapturingShell()
        _ = try await ContainerImagePreparer(shell: shell).prepare(options(), versions: versions)
        let context = try XCTUnwrap(shell.builds.first?.argv.last)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context), "context left behind: \(context)")
    }

    func testBuildFailureIsReportedWithItsReasonAndRemovesTheContext() async throws {
        let shell = BuildContextCapturingShell()
        shell.inner.failOn = "build"
        do {
            _ = try await ContainerImagePreparer(shell: shell).prepare(options(), versions: versions)
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("container build failed"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("boom"), error.localizedDescription)
        }
        let context = try XCTUnwrap(shell.builds.first?.argv.last)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context))
    }

    func testNonDebianBaseIsRejectedWithAClearReason() async {
        let shell = BuildContextCapturingShell()
        shell.inner.defaultResult = ShellResult(
            exitCode: 1, stdout: "", stderr: "#4 0.1 kinhin: base image has no apt-get\nERROR: process did not complete"
        )
        do {
            _ = try await ContainerImagePreparer(shell: shell).prepare(
                options(image: "alpine:3"), versions: versions)
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("'alpine:3' isn't Debian/Ubuntu-based"))
        }
    }

    func testManagedToolchainFailureIsNamedAsSuch() async {
        let shell = BuildContextCapturingShell()
        shell.inner.defaultResult = ShellResult(
            exitCode: 1, stdout: "",
            stderr: "ERROR: process \"/bin/bash -l /kinhin-bake/toolchains.sh\" did not complete successfully")
        var opts = options()
        opts.toolchains = KinhinConfig.ToolchainsConfig(specs: ["node@22"])
        do {
            _ = try await ContainerImagePreparer(shell: shell).prepare(opts, versions: versions)
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("managed toolchain install failed"))
        }
    }

    func testBakingWithoutAStoredTokenFailsBeforeBuilding() async {
        let shell = BuildContextCapturingShell()
        var opts = options()
        opts.storedTokens = []
        do {
            _ = try await ContainerImagePreparer(shell: shell).prepare(opts, versions: versions)
            XCTFail("expected a failure")
        } catch {}
        XCTAssertTrue(shell.inner.calls.isEmpty)
    }
}
