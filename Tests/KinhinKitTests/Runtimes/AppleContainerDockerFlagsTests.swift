import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `container.docker` and `container.flags` (#75) in the Apple container runtime: the `container run` argv (kinhin's
/// flags, then `--cap-add ALL`, then the user's flags, then `--rm IMAGE ...`, and byte-identical to before with both
/// off), the dockerd start ahead of registration, and the engine handing both from the config to the runtime.
final class AppleContainerDockerFlagsTests: XCTestCase {
    private let bin = "/usr/local/bin/container"
    private let tail = ["--rm", "kinhin-ci-linux", "/bin/bash", "-lc", "while true; do sleep 3600; done"]

    private func provisionArgv(docker: Bool = false, flags: [String] = []) async throws -> [String] {
        let shell = FakeShell()
        let runtime = AppleContainerRuntime(
            shell: shell, image: "kinhin-ci-linux", cpus: 3, memoryGB: 6, docker: docker, flags: flags, binPath: bin)
        try await runtime.provision(id: "kinhin-abc", route: makeRoute())
        XCTAssertEqual(shell.calls.count, 2, "list (idempotency check) + run")
        return try XCTUnwrap(shell.calls.last)
    }

    private var kinhinFlags: [String] {
        [bin, "run", "--detach", "--name", "kinhin-abc", "--cpus", "3", "--memory", "6144M"]
    }

    // MARK: - Provision argv

    func testArgvIsUnchangedWithBothOff() async throws {
        let argv = try await provisionArgv()
        XCTAssertEqual(argv, kinhinFlags + tail)
        XCTAssertFalse(argv.contains("--cap-add"))
    }

    func testDockerAddsEveryCapability() async throws {
        let argv = try await provisionArgv(docker: true)
        XCTAssertEqual(argv, kinhinFlags + ["--cap-add", "ALL"] + tail)
    }

    func testFlagsComeAfterKinhinsOwnAndBeforeTheImage() async throws {
        let argv = try await provisionArgv(flags: ["--shm-size", "2g", "--dns", "1.1.1.1"])
        XCTAssertEqual(argv, kinhinFlags + ["--shm-size", "2g", "--dns", "1.1.1.1"] + tail)
    }

    func testDockerCapabilitiesComeBeforeTheUsersFlags() async throws {
        let argv = try await provisionArgv(docker: true, flags: ["--shm-size", "2g", "--dns", "1.1.1.1"])
        XCTAssertEqual(argv, kinhinFlags + ["--cap-add", "ALL", "--shm-size", "2g", "--dns", "1.1.1.1"] + tail)
    }

    func testAFlagWithSpacesStaysOneArgvElement() async throws {
        let argv = try await provisionArgv(flags: ["--env", "GREETING=hello world; rm -rf /"])
        XCTAssertTrue(argv.contains("GREETING=hello world; rm -rf /"), "\(argv)")
        XCTAssertEqual(Array(argv.suffix(tail.count + 2).prefix(2)), ["--env", "GREETING=hello world; rm -rf /"])
    }

    func testPoolRunFlagsHelper() {
        XCTAssertEqual(AppleContainerRuntime.poolRunFlags(docker: false, flags: []), [])
        XCTAssertEqual(AppleContainerRuntime.poolRunFlags(docker: true, flags: []), ["--cap-add", "ALL"])
        XCTAssertEqual(
            AppleContainerRuntime.poolRunFlags(docker: true, flags: ["--init"]), ["--cap-add", "ALL", "--init"])
    }

    func testRecoveryStartsTheExistingContainerWithoutRunFlags() async throws {
        let shell = FakeShell()
        shell.defaultResult = ShellResult(exitCode: 0, stdout: "kinhin-abc\n", stderr: "")
        let runtime = AppleContainerRuntime(
            shell: shell, image: "kinhin-ci-linux", docker: true, flags: ["--init"], binPath: bin)
        try await runtime.provision(id: "kinhin-abc", route: makeRoute())
        XCTAssertEqual(shell.calls.last, [bin, "start", "kinhin-abc"])
    }

    // MARK: - Registration

    private func registrationScript(docker: Bool) async throws -> String {
        let runtime = AppleContainerRuntime(shell: FakeShell(), image: "img", docker: docker, binPath: bin)
        let github = GitHubForge(
            credentials: .github(token: "t", scope: "acme/widgets"), labels: ["kinhin"], client: FakeGitHub())
        return try await runtime.registrationScript(
            forge: github, token: "RT", name: "kinhin-1", runnerCount: 1, route: makeRoute(), labels: nil)
    }

    func testRegistrationStartsDockerdFirstWhenDockerIsOn() async throws {
        let script = try await registrationScript(docker: true)
        XCTAssertTrue(script.hasPrefix(RunnerBootstrap.linuxDockerDaemonScript()), script)
        let dockerd = try XCTUnwrap(script.range(of: "setsid nohup dockerd"))
        let errexit = try XCTUnwrap(script.range(of: "set -euo pipefail"))
        let register = try XCTUnwrap(script.range(of: "./config.sh --url"))
        XCTAssertLessThan(dockerd.upperBound, errexit.lowerBound, "dockerd starts before the forge script")
        XCTAssertLessThan(dockerd.upperBound, register.lowerBound, "dockerd starts before the runner registers")

        let syntax = try await Shell().run(["/bin/bash", "-n", "-c", script], cwd: nil, timeout: 10)
        XCTAssertTrue(syntax.succeeded, "composed registration script: \(syntax.stderr)")
    }

    func testRegistrationIsUnchangedWithDockerOff() async throws {
        let script = try await registrationScript(docker: false)
        XCTAssertFalse(script.contains("dockerd"), script)
        XCTAssertFalse(script.contains("/proc/sys"), script)
    }

    func testTheDockerdScriptRemountsProcSysWaitsAndFailsClearly() async throws {
        let script = RunnerBootstrap.linuxDockerDaemonScript(timeoutSeconds: 45)
        XCTAssertTrue(script.contains("if ! docker info >/dev/null 2>&1; then"), "idempotent: a running daemon is kept")
        XCTAssertTrue(script.contains("command -v dockerd"), "a missing dockerd fails with a clear message")
        XCTAssertTrue(script.contains("kinhin image prepare --container"))
        XCTAssertTrue(script.contains("mount -o remount,rw /proc/sys"))
        XCTAssertTrue(script.contains("setsid nohup dockerd >/var/log/dockerd.log 2>&1 < /dev/null &"))
        XCTAssertTrue(script.contains("$(seq 1 45)"), "waits up to the timeout")
        XCTAssertTrue(script.contains("tail -n 10 /var/log/dockerd.log >&2"), "a failed start shows the log's end")
        let syntax = try await Shell().run(["/bin/bash", "-n", "-c", script], cwd: nil, timeout: 10)
        XCTAssertTrue(syntax.succeeded, syntax.stderr)
    }

    // MARK: - Engine

    func testTheEngineHandsDockerAndFlagsToTheRuntime() async throws {
        let shell = ContainerFakingShell()
        var config = makeTestConfig()
        config.container = .init(
            image: "kinhin-ci-linux", cpus: 2, memoryGB: 4, docker: true, flags: ["--shm-size", "2g"])
        let github = FakeGitHub()
        github.queueDepth = 1
        let engine = FleetEngine(
            config: config, github: github, tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            containerShell: shell)

        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            shell.argvSnapshot().contains { $0.contains("exec") && $0.contains("/bin/bash") }
        }
        let argvs = shell.argvSnapshot()
        let run = try XCTUnwrap(argvs.first { $0.dropFirst().first == "run" })
        let memory = try XCTUnwrap(run.firstIndex(of: "--memory"))
        XCTAssertEqual(
            Array(run[(memory + 2)...].prefix(5)), ["--cap-add", "ALL", "--shm-size", "2g", "--rm"], "\(run)")
        let exec = try XCTUnwrap(argvs.first { $0.contains("exec") && $0.contains("<stdin>") })
        XCTAssertTrue(exec.last?.contains("setsid nohup dockerd") == true, "registration starts dockerd")
    }

    // MARK: - Helpers

    private func makeRoute() -> RepoRoute {
        RepoRoute(repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 30)
    }
}
