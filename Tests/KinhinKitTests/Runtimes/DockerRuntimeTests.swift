import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Covers the Docker execution runtime: health probing across the Docker
/// Desktop/OrbStack/colima providers, `docker run` provision argv (resource
/// limits per slot), idempotent recovery, `docker exec` registration, boot
/// wait, teardown, the config section, and the engine lifecycle dispatching
/// through the runtime seam (no SSH, no IP).
final class DockerRuntimeTests: XCTestCase {
    private let bin = "/usr/local/bin/docker"

    // MARK: - Health

    func testHealthReportsMissingWhenBinUnresolvable() async {
        let runtime = DockerRuntime(
            shell: FakeShell(), image: "img", cpus: 2, memoryGB: 4,
            binPath: "/nonexistent/docker",
            exists: { _ in false }
        )
        let health = await runtime.health()
        guard case .missing(let tool, _) = health else {
            return XCTFail("expected .missing, got \(health)")
        }
        XCTAssertEqual(tool, "docker")
    }

    func testHealthReportsBrokenWhenDaemonUnreachable() async {
        let shell = FakeShell()
        shell.defaultResult = ShellResult(exitCode: 1, stdout: "", stderr: "Cannot connect to the Docker daemon")
        let runtime = DockerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: bin,
            exists: { _ in true }
        )
        let health = await runtime.health()
        guard case .broken(let why) = health else {
            return XCTFail("expected .broken, got \(health)")
        }
        XCTAssertTrue(why.contains("daemon is not reachable"), why)
    }

    func testHealthReadyWhenInfoSucceeds() async {
        let shell = FakeShell()
        shell.defaultResult = ShellResult(exitCode: 0, stdout: "27.3.1\n", stderr: "")
        let runtime = DockerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: bin,
            exists: { _ in true }
        )
        let health = await runtime.health()
        XCTAssertEqual(health, .ready)
        // The probe asks `docker info` — one command covers every provider.
        XCTAssertTrue(shell.calls[0].contains("info"))
    }

    // MARK: - Provision

    func testProvisionRunsDetachedWithResourceLimits() async throws {
        let shell = FakeShell()
        let runtime = DockerRuntime(
            shell: shell, image: "ghcr.io/acme/ci", cpus: 3, memoryGB: 6,
            binPath: bin
        )
        try await runtime.provision(id: "kinhin-abc", route: makeRoute())
        XCTAssertEqual(shell.calls.count, 2)  // ps (idempotency check) + run
        let runArgv = shell.calls[1]
        XCTAssertEqual(runArgv.first, bin)
        for flag in [
            "run", "--detach", "--name", "kinhin-abc", "--cpus", "3",
            "--memory", "6144M", "--platform", "linux/arm64", "--rm",
        ] {
            XCTAssertTrue(runArgv.contains(flag), "run argv must contain \(flag): \(runArgv)")
        }
        XCTAssertTrue(runArgv.contains("ghcr.io/acme/ci"))
    }

    func testProvisionIsIdempotentForExistingContainer() async throws {
        let shell = FakeShell()
        // `docker ps --all --quiet` finds the container → start, never run.
        shell.responses = [ShellResult(exitCode: 0, stdout: "kinhin-abc\n", stderr: "")]
        let runtime = DockerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: bin
        )
        try await runtime.provision(id: "kinhin-abc", route: makeRoute())
        let argvs = shell.calls
        XCTAssertTrue(argvs[0].contains("ps"))
        XCTAssertTrue(argvs[1].contains("start"), "recovery restarts the existing container: \(argvs)")
        XCTAssertFalse(argvs.contains { $0.contains("run") }, "no second container is created")
    }

    // MARK: - Registration

    func testExecScriptUsesDockerExec() async throws {
        let shell = FakeShell()
        let runtime = DockerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: bin
        )
        _ = try await runtime.execScript("kinhin-abc", "echo hi")
        XCTAssertEqual(shell.calls.first, [bin, "exec", "kinhin-abc", "/bin/bash", "-lc", "echo hi"])
    }

    func testRegistrationScriptUsesLinuxFlavors() async throws {
        let runtime = DockerRuntime(
            shell: FakeShell(), image: "img", cpus: 2, memoryGB: 4,
            binPath: bin
        )
        let github = GitHubForge(
            credentials: .github(token: "t", scope: "acme/widgets"),
            labels: ["kinhin"],
            client: FakeGitHub()
        )
        let script = try await runtime.registrationScript(
            forge: github, token: "RT", name: "kinhin-1", runnerCount: 2,
            route: makeRoute(), labels: nil
        )
        XCTAssertTrue(script.contains("/opt/actions-runner"))
        XCTAssertTrue(script.contains("actions-runner-2"))
        XCTAssertTrue(script.contains("--name 'kinhin-1-r1'"))

        let gitea = GiteaForge(
            credentials: .gitea(token: "t", scope: "acme/widgets", instance: "https://gitea.example.com"),
            labels: ["linux:host"],
            client: GiteaClient(
                credentials: GiteaCredentials(token: "t", scope: "acme/widgets", instance: "https://gitea.example.com")),
            demandFloor: 0,
            registrationToken: "GT"
        )
        let giteaScript = try await runtime.registrationScript(
            forge: gitea, token: "GT", name: "kinhin-1", runnerCount: 1,
            route: makeRoute(), labels: nil
        )
        XCTAssertTrue(giteaScript.contains("/opt/gitea-runner"))
    }

    // MARK: - Boot wait

    func testAwaitReadyPollsUntilContainerAppears() async throws {
        let shell = FakeShell()
        shell.responses = [
            ShellResult(exitCode: 1, stdout: "", stderr: ""),  // not yet
            ShellResult(exitCode: 0, stdout: "other\n", stderr: ""),  // still not ours
            ShellResult(exitCode: 0, stdout: "other\nkinhin-abc\n", stderr: ""),  // up
        ]
        let runtime = DockerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: bin
        )
        let handle = try await runtime.awaitReady(id: "kinhin-abc", timeout: 10)
        XCTAssertNil(handle, "exec transport: no address to dial")
        XCTAssertEqual(shell.calls.count, 3)
    }

    func testAwaitReadyTimesOut() async {
        let shell = FakeShell()  // always-empty ps output
        let runtime = DockerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: bin
        )
        do {
            _ = try await runtime.awaitReady(id: "kinhin-abc", timeout: 0.2)
            XCTFail("expected timeout")
        } catch let error as RuntimeWatchError {
            guard case .registrationTimeout = error else {
                return XCTFail("expected registrationTimeout, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Teardown + enumeration

    func testTeardownForceRemoves() async throws {
        let shell = FakeShell()
        let runtime = DockerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: bin
        )
        await runtime.teardown(id: "kinhin-abc")
        XCTAssertEqual(shell.calls.first, [bin, "rm", "--force", "kinhin-abc"])
    }

    func testExistingInstanceIDsParsesPSOutput() async throws {
        let shell = FakeShell()
        shell.defaultResult = ShellResult(exitCode: 0, stdout: "a\nb\nc\n", stderr: "")
        let runtime = DockerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: bin
        )
        let ids = await runtime.existingInstanceIDs()
        XCTAssertEqual(ids, ["a", "b", "c"])
    }

    // MARK: - Config

    // MARK: - Helpers

    private func makeRoute(cacheMount: Bool = false) -> RepoRoute {
        RepoRoute(repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 30, cacheMount: cacheMount)
    }

    func waitUntil(timeout: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
