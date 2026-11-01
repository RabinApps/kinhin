import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class LinuxImageBakerTests: XCTestCase {
    private func options() -> LinuxImageOptions {
        LinuxImageOptions(
            image: "missing-base", target: "out", storedTokens: [.github])
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
            image: "ubuntu:24.04", target: "out", storedTokens: [.github])
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

    // MARK: - Docker (container.docker)

    private func bakeScript(docker: Bool) async throws -> String {
        let shell = FakeShell()
        let opts = LinuxImageOptions(image: "ubuntu:24.04", target: "out", storedTokens: [.github], docker: docker)
        _ = try await ContainerImagePreparer(shell: shell).prepare(opts, versions: .init(github: "1", gitea: "1"))
        let install = try XCTUnwrap(shell.calls.first { $0.contains("-lc") }, "\(shell.calls)")
        return try XCTUnwrap(install.last, "\(install)")
    }

    func testBakeInstallsDockerOnlyWhenAsked() async throws {
        let plain = try await bakeScript(docker: false)
        XCTAssertFalse(plain.contains("docker.io"), "no Docker unless container.docker is on")

        let script = try await bakeScript(docker: true)
        XCTAssertTrue(script.contains(RunnerBootstrap.linuxDockerInstallScript()), script)
        let common = try XCTUnwrap(script.range(of: "command -v jq"), "no CI prerequisites")
        let docker = try XCTUnwrap(script.range(of: "docker_packages=\"docker.io\""), "no Docker install")
        let agent = try XCTUnwrap(script.range(of: "mkdir -p /opt/actions-runner"), "no GitHub agent install")
        XCTAssertLessThan(common.upperBound, docker.lowerBound, "Docker installs after the CI prerequisites")
        XCTAssertLessThan(docker.upperBound, agent.lowerBound, "Docker installs before the agents")

        let syntax = try await Shell().run(["/bin/bash", "-n", "-c", script], cwd: nil, timeout: 10)
        XCTAssertTrue(syntax.succeeded, "composed bake script: \(syntax.stderr)")
    }

    func testDockerInstallAddsTheOptionalPluginsAndHoldsBackServices() {
        let script = RunnerBootstrap.linuxDockerInstallScript()
        XCTAssertTrue(script.hasPrefix("# Docker"), script)
        XCTAssertTrue(script.contains("if ! command -v dockerd >/dev/null 2>&1; then"), "skipped when present")
        XCTAssertTrue(script.contains("docker_packages=\"$docker_packages iptables\""))
        XCTAssertTrue(script.contains("for optional in docker-buildx docker-compose-v2; do"))
        XCTAssertTrue(script.contains("apt-cache show \"$optional\""), "plugins only where the distribution has them")
        XCTAssertTrue(script.contains("apt-get install -y --no-install-recommends $docker_packages"))
        XCTAssertTrue(script.contains("printf '#!/bin/sh\\nexit 101\\n' > /usr/sbin/policy-rc.d"))
    }

    func testDockerInstallDoesNothingWhenTheBaseHasDockerd() async throws {
        // A fake dockerd on PATH and an apt-get that records any call: with dockerd present, apt is never run.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docker-bake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let calls = dir.appendingPathComponent("apt-calls")
        for (tool, body) in [("dockerd", "echo 'Docker version 99'"), ("apt-get", "echo \"$@\" >> '\(calls.path)'")] {
            let url = dir.appendingPathComponent(tool)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let script =
            "PATH='\(dir.path)':/usr/bin:/bin\nset -euo pipefail\n" + RunnerBootstrap.linuxDockerInstallScript()
        let result = try await Shell().run(["/bin/bash", "-c", script], cwd: nil, timeout: 10)
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertTrue(result.stdout.contains("Docker version 99"), result.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path), "apt-get must not run")
    }
}
