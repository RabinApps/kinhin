import XCTest

@testable import KinhinKit

/// Covers the Apple `container` execution runtime (github.com/apple/container):
/// health probing, provision argv/idempotency, exec-based registration, boot
/// wait, teardown, the config section, and the engine switching its whole
/// lifecycle (no SSH, no IP) when `container:` is configured.
final class AppleContainerRuntimeTests: XCTestCase {
    // MARK: - Health

    func testHealthReportsMissingWhenBinUnresolvable() async {
        let runtime = AppleContainerRuntime(
            shell: RecordingShell(), image: "img", cpus: 2, memoryGB: 4,
            binPath: "/nonexistent/container",
            exists: { _ in false }
        )
        let health = await runtime.health()
        guard case .missing(let tool, _) = health else {
            return XCTFail("expected .missing, got \(health)")
        }
        XCTAssertEqual(tool, "apple container")
    }

    func testHealthReportsBrokenWhenServiceDown() async {
        let shell = RecordingShell()
        shell.result = ShellResult(exitCode: 1, stdout: "", stderr: "no api")
        let runtime = AppleContainerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: "/usr/local/bin/container",
            exists: { _ in true }
        )
        let health = await runtime.health()
        guard case .broken(let why) = health else {
            return XCTFail("expected .broken, got \(health)")
        }
        XCTAssertTrue(why.contains("container system start"))
    }

    func testHealthReadyWhenStatusSucceeds() async {
        let runtime = AppleContainerRuntime(
            shell: RecordingShell(), image: "img", cpus: 2, memoryGB: 4,
            binPath: "/usr/local/bin/container",
            exists: { _ in true }
        )
        let health = await runtime.health()
        XCTAssertEqual(health, .ready)
    }

    // MARK: - Provision

    func testProvisionRunsDetachedWithResourceLimits() async throws {
        let shell = RecordingShell()
        let runtime = AppleContainerRuntime(
            shell: shell, image: "kinhin-ci-linux", cpus: 3, memoryGB: 6,
            binPath: "/usr/local/bin/container"
        )
        try await runtime.provision(id: "kinhin-abc", route: makeRoute())
        XCTAssertEqual(shell.argvs.count, 2)  // list (idempotency check) + run
        let runArgv = shell.argvs[1]
        XCTAssertEqual(runArgv.first, "/usr/local/bin/container")
        XCTAssertTrue(runArgv.contains("run"))
        XCTAssertTrue(runArgv.contains("--detach"))
        XCTAssertTrue(runArgv.contains("--name"))
        XCTAssertTrue(runArgv.contains("kinhin-abc"))
        XCTAssertTrue(runArgv.contains("--cpus"))
        XCTAssertTrue(runArgv.contains("3"))
        XCTAssertTrue(runArgv.contains("--memory"))
        XCTAssertTrue(runArgv.contains("6144M"), "6 GB should render as 6144M, got \(runArgv)")
        XCTAssertTrue(runArgv.contains("kinhin-ci-linux"))
    }

    func testProvisionIsIdempotentForExistingContainer() async throws {
        let shell = RecordingShell()
        shell.result = ShellResult(exitCode: 0, stdout: "kinhin-abc\n", stderr: "")
        let runtime = AppleContainerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: "/usr/local/bin/container"
        )
        try await runtime.provision(id: "kinhin-abc", route: makeRoute())
        let runArgv = shell.argvs[1]
        XCTAssertTrue(runArgv.contains("start"), "existing container should be started, not re-run: \(runArgv)")
        XCTAssertFalse(runArgv.contains("--detach"))
    }

    // MARK: - Registration transport

    func testExecScriptUsesContainerExec() async throws {
        let shell = RecordingShell()
        let runtime = AppleContainerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: "/usr/local/bin/container"
        )
        _ = try await runtime.execScript("kinhin-abc", "echo hi")
        let argv = shell.argvs[0]
        XCTAssertEqual(argv.first, "/usr/local/bin/container")
        XCTAssertTrue(argv.contains("exec"))
        XCTAssertTrue(argv.contains("kinhin-abc"))
        XCTAssertTrue(argv.contains("/bin/bash"))
        XCTAssertTrue(argv.contains("-lc"))
        XCTAssertTrue(argv.contains("echo hi"))
    }

    // MARK: - Bootstrap script selection

    func testRegistrationScriptUsesLinuxFlavors() async throws {
        let shell = RecordingShell()
        let runtime = AppleContainerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: "/usr/local/bin/container"
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
        XCTAssertTrue(script.contains("linux runner(s) started"))

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
        XCTAssertTrue(giteaScript.contains("linux gitea runner(s) started"))
    }

    // MARK: - Boot wait

    func testAwaitRunningPollsUntilContainerAppears() async throws {
        let shell = ScriptedShell()
        shell.responses = [
            ShellResult(exitCode: 1, stdout: "", stderr: ""),  // not yet
            ShellResult(exitCode: 1, stdout: "", stderr: ""),  // not yet
            ShellResult(exitCode: 0, stdout: "kinhin-abc\n", stderr: ""),  // up
        ]
        let runtime = AppleContainerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: "/usr/local/bin/container"
        )
        let handle = try await runtime.awaitRunning("kinhin-abc", timeout: 10, pollInterval: 0.05)
        XCTAssertEqual(handle, "kinhin-abc")
        XCTAssertEqual(shell.argvs.count, 3)
    }

    func testAwaitRunningTimesOut() async {
        let shell = RecordingShell()  // always-empty list output
        let runtime = AppleContainerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: "/usr/local/bin/container"
        )
        do {
            _ = try await runtime.awaitRunning("kinhin-abc", timeout: 0.2, pollInterval: 0.05)
            XCTFail("expected timeout")
        } catch let error as RuntimeWatchError {
            guard case .registrationTimeout = error else {
                return XCTFail("expected registrationTimeout, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Teardown

    func testTeardownForceDeletes() async throws {
        let shell = RecordingShell()
        let runtime = AppleContainerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: "/usr/local/bin/container"
        )
        await runtime.teardown(id: "kinhin-abc")
        let argv = try XCTUnwrap(shell.argvs.first)
        XCTAssertTrue(argv.contains("delete"))
        XCTAssertTrue(argv.contains("--force"))
        XCTAssertTrue(argv.contains("kinhin-abc"))
    }

    // MARK: - Config

    func testContainerConfigParsingAndValidation() throws {
        let yaml = """
            repo: "acme/widgets"
            labels: ["kinhin"]
            container:
              image: "kinhin-ci-linux"
              cpus: 2
              memory_gb: 4
            """
        let cfg = try ConfigLoader.parse(yaml)
        let container = try XCTUnwrap(cfg.container)
        XCTAssertEqual(container.image, "kinhin-ci-linux")
        XCTAssertEqual(container.cpus, 2)
        XCTAssertEqual(container.memoryGB, 4)

        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme/widgets"
                labels: ["kinhin"]
                container:
                  image: ""
                """)
        ) { error in
            XCTAssertTrue("\(error)".contains("container.image must not be empty"))
        }
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme/widgets"
                labels: ["kinhin"]
                container:
                  image: "x"
                  memory_gb: 1
                """)
        ) { error in
            XCTAssertTrue("\(error)".contains("container.memory_gb must be >= 2"))
        }
    }

    func testConfigWithoutContainerSectionIsNil() throws {
        let cfg = try ConfigLoader.parse("repo: \"acme/widgets\"\nlabels: [\"kinhin\"]")
        XCTAssertNil(cfg.container)
    }

    // MARK: - Engine integration

    func testEngineWithContainerConfigRunsContainerLifecycle() async throws {
        let shell = ContainerFakingShell()
        var config = makeTestConfig()
        config.container = .init(image: "kinhin-ci-linux", cpus: 2, memoryGB: 4)
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = FleetEngine(
            config: config, github: github, tart: FakeTart(),
            store: makeTestStore(), ssh: ssh, host: testHost,
            containerShell: shell
        )

        // Spawn: a record appears stamped with the appleContainer runtime.
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.first?.phase == .registering || status.records.first?.phase == .ready
        }
        let status = await engine.status()
        let record = try XCTUnwrap(status.records.first)
        XCTAssertEqual(record.runtime, RuntimeID.appleContainer.rawValue)
        XCTAssertEqual(status.runtime, RuntimeID.appleContainer.rawValue)
        XCTAssertNil(record.ip, "container records carry no IP — there is no SSH transport")

        // The lifecycle used container run/exec (provision) and exec (registration).
        let argvs = await shell.argvSnapshot()
        XCTAssertTrue(argvs.contains { $0.contains("run") && $0.contains("--name") })
        XCTAssertTrue(argvs.contains { $0.contains("exec") && $0.contains("/bin/bash") })
        // And never SSH'd (the container path has no SSH transport).
        XCTAssertTrue(ssh.scripts.isEmpty, "SSH transport must be unused")
    }

    func testEngineWithoutContainerConfigKeepsTartLifecycle() async throws {
        let github = FakeGitHub()
        github.queueDepth = 1
        let tart = FakeTart()
        let ssh = FakeSSH()
        let engine = FleetEngine(
            config: makeTestConfig(), github: github, tart: tart,
            store: makeTestStore(), ssh: ssh, host: testHost
        )
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            return status.records.first?.phase == .registering || status.records.first?.phase == .ready
        }
        let status = await engine.status()
        XCTAssertEqual(status.runtime, RuntimeID.tart.rawValue)
        XCTAssertEqual(status.records.first?.runtime, RuntimeID.tart.rawValue)
        XCTAssertNotNil(status.records.first?.ip, "tart records carry the VM IP")
        XCTAssertTrue(!ssh.scripts.isEmpty, "tart lifecycle registers over SSH")
        XCTAssertEqual(tart.cloneCalls.count, 1)
    }

    // MARK: - Helpers

    private func makeRoute() -> RepoRoute {
        RepoRoute(repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 30)
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

/// ShellRunning double with a queue of scripted responses (pops until empty,
/// then returns the default). Records all argvs.
final class ScriptedShell: ShellRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var argvs: [[String]] = []
    var responses: [ShellResult] = []
    var defaultResult = ShellResult(exitCode: 0, stdout: "", stderr: "")

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        lock.lock()
        argvs.append(argv)
        let result = responses.isEmpty ? defaultResult : responses.removeFirst()
        lock.unlock()
        return result
    }

    func argvSnapshot() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return argvs
    }
}

/// A shell double that models `container list` as real state: `run --name X`
/// creates container X, `delete --force X` removes it, and list returns the
/// current names — so provision/awaitRunning/provision-after-recovery behave
/// like the real CLI. Other argvs return success. Matches the binary on any
/// install prefix so the test stays independent of the host PATH.
final class ContainerFakingShell: ShellRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var argvs: [[String]] = []
    private var containers: Set<String> = []

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        lock.lock()
        defer { lock.unlock() }
        argvs.append(argv)
        guard
            argv.first == nil || argv.first == "/usr/local/bin/container" || argv.first?.hasSuffix("container") == true
        else {
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        switch argv.dropFirst().first {
        case "list":
            return ShellResult(exitCode: 0, stdout: containers.joined(separator: "\n"), stderr: "")
        case "run":
            if let nameIdx = argv.firstIndex(of: "--name"), argv.count > nameIdx + 1 {
                containers.insert(argv[nameIdx + 1])
            }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        case "start":
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        case "delete":
            if let last = argv.last { containers.remove(last) }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        default:
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    func argvSnapshot() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return argvs
    }
}
