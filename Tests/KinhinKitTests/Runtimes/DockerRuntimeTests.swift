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

    func testDockerConfigParsingAndValidation() throws {
        let cfg = try ConfigLoader.parse(
            """
            repo: "acme"
            labels: ["kinhin"]
            docker:
              image: "ghcr.io/acme/kinhin-ci-linux"
              cpus: 2
              memory_gb: 4
              max_slots: 6
            """)
        let docker = try XCTUnwrap(cfg.docker)
        XCTAssertEqual(docker.image, "ghcr.io/acme/kinhin-ci-linux")
        XCTAssertEqual(docker.cpus, 2)
        XCTAssertEqual(docker.memoryGB, 4)
        XCTAssertEqual(docker.maxSlots, 6)

        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme"
                labels: ["kinhin"]
                docker:
                  image: ""
                """)
        ) { error in
            XCTAssertTrue("\(error)".contains("docker.image must not be empty"), "\(error)")
        }
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme"
                labels: ["kinhin"]
                docker:
                  cpus: 0
                """)
        ) { error in
            XCTAssertTrue("\(error)".contains("docker.image must not be empty"), "\(error)")
        }
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme"
                labels: ["kinhin"]
                docker:
                  image: "img"
                  max_slots: 0
                """)
        ) { error in
            XCTAssertTrue("\(error)".contains("docker.max_slots must be >= 1"), "\(error)")
        }
    }

    // MARK: - Engine integration

    func testEngineWithDockerConfigRunsDockerLifecycle() async throws {
        let shell = DockerFakingShell()
        var config = makeTestConfig()
        config.docker = .init(image: "ghcr.io/acme/kinhin-ci-linux", cpus: 2, memoryGB: 4)
        let github = FakeGitHub()
        github.queueDepth = 1
        let ssh = FakeSSH()
        let engine = FleetEngine(
            config: config, github: github, tart: FakeTart(),
            store: makeTestStore(), ssh: ssh, host: testHost,
            containerShell: shell
        )

        // Spawn: a record appears stamped with the docker runtime.
        try await engine.reconcileOnce()
        try await waitUntil(timeout: 10) {
            let status = await engine.status()
            let phase = status.records.first?.phase
            return phase == .registering || phase == .ready
        }
        let status = await engine.status()
        let record = try XCTUnwrap(status.records.first)
        XCTAssertEqual(record.runtime, RuntimeID.docker.rawValue)
        XCTAssertEqual(
            status.runtime, RuntimeID.docker.rawValue, "docker is the primary runtime when only docker: is configured")
        XCTAssertNil(record.ip, "docker records carry no IP — there is no SSH transport")

        // The lifecycle used docker run/exec (provision) and exec (registration).
        let argvs = shell.argvSnapshot()
        XCTAssertTrue(argvs.contains { $0.contains("run") && $0.contains("--name") })
        XCTAssertTrue(argvs.contains { $0.contains("exec") && $0.contains("/bin/bash") })
        // And never SSH'd (the docker path has no SSH transport).
        XCTAssertTrue(ssh.scripts.isEmpty, "SSH transport must be unused")
    }

    func testEngineWithoutDockerConfigKeepsTartLifecycle() async throws {
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
        XCTAssertTrue(!ssh.scripts.isEmpty, "tart lifecycle registers over SSH")
    }

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

    // MARK: - Shared toolchain cache (Linux path, Docker flavor)

    func testProvisionMountsCacheOnlyWhenShareCacheIsOn() async throws {
        let shell = FakeShell()
        let runtime = DockerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: bin
        )
        try await runtime.provision(id: "kinhin-a", route: makeRoute())
        var runArgv = try XCTUnwrap(shell.calls.last { $0.contains("run") })
        XCTAssertFalse(runArgv.contains("--volume"), "share_cache off → no bind mount")

        try await runtime.provision(id: "kinhin-b", route: makeRoute(cacheMount: true))
        runArgv = try XCTUnwrap(shell.calls.last { $0.contains("run") })
        XCTAssertTrue(runArgv.contains("--volume"))
        XCTAssertTrue(runArgv.contains(ToolchainCacheMount.volumeSpec(host: Paths.toolchainCache.path)))
    }

    func testRegistrationScriptPrefixesLinuxCacheExportsWhenMounted() async throws {
        let runtime = DockerRuntime(
            shell: FakeShell(), image: "img", cpus: 2, memoryGB: 4,
            binPath: bin,
            toolchainsConfig: { KinhinConfig.ToolchainsConfig(specs: ["node@22", "pnpm"]) }
        )
        let github = GitHubForge(
            credentials: .github(token: "tok", scope: "acme/widgets"),
            labels: ["kinhin"],
            client: FakeGitHub()
        )
        let script = try await runtime.registrationScript(
            forge: github, token: "RT", name: "kinhin-1", runnerCount: 1,
            route: makeRoute(cacheMount: true), labels: nil
        )
        XCTAssertTrue(script.contains("export NPM_CONFIG_CACHE=\"/var/kinhin-cache/npm\""))
        XCTAssertTrue(script.contains("export npm_config_store_dir=\"/var/kinhin-cache/pnpm-store\""))
        XCTAssertTrue(script.contains("/opt/actions-runner"), "registration script itself still present")
        XCTAssertTrue(
            script.range(of: "export NPM_CONFIG_CACHE")!.lowerBound < script.range(of: "config.sh --url")!.lowerBound,
            "exports come first")
    }

    func testRegistrationScriptWithoutMountHasNoExports() async throws {
        let runtime = DockerRuntime(
            shell: FakeShell(), image: "img", cpus: 2, memoryGB: 4,
            binPath: bin,
            toolchainsConfig: { KinhinConfig.ToolchainsConfig(specs: ["node@22"]) }
        )
        let github = GitHubForge(
            credentials: .github(token: "tok", scope: "acme/widgets"),
            labels: ["kinhin"],
            client: FakeGitHub()
        )
        let script = try await runtime.registrationScript(
            forge: github, token: "RT", name: "kinhin-1", runnerCount: 1,
            route: makeRoute(), labels: nil
        )
        XCTAssertFalse(script.contains("export NPM_CONFIG_CACHE"), "no mount → no cache exports")
    }

    func testPrepareAlwaysBindMountsTheCache() async throws {
        let shell = FakeShell()
        let preparer = DockerImagePreparer(shell: shell)
        try await preparer.prepare(
            .init(
                image: "ubuntu:24.04", target: "kinhin-ci", hasGitHubToken: true, hasGiteaToken: false,
                hasGitLabToken: false))
        let runArgv = try XCTUnwrap(shell.calls.first { $0.contains("run") })
        XCTAssertTrue(runArgv.contains("--volume"), "prepare bind-mounts the host cache unconditionally: \(runArgv)")
        XCTAssertTrue(runArgv.contains(ToolchainCacheMount.volumeSpec(host: Paths.toolchainCache.path)))
    }

    func testPrepareBakesManagedToolchainsBeforeCommit() async throws {
        let shell = FakeShell()
        let preparer = DockerImagePreparer(shell: shell)
        try await preparer.prepare(
            .init(
                image: "ubuntu:24.04", target: "kinhin-ci",
                toolchains: KinhinConfig.ToolchainsConfig(specs: ["node@22"]),
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false
            ))
        // Order: run → ready-probe exec → agent exec → managed exec → commit.
        let runIdx = try XCTUnwrap(shell.calls.firstIndex { $0.contains("run") })
        let bashExecs = shell.calls.enumerated().filter { _, argv in
            argv.contains("exec") && argv.contains("/bin/bash")
        }
        XCTAssertEqual(bashExecs.count, 2, "agent install + managed toolchains: \(shell.calls)")
        let managedExec = shell.calls[bashExecs[1].offset].joined(separator: " ")
        XCTAssertTrue(managedExec.contains("mise use --global node@22"), "second exec is the managed toolchain script")
        let commitIdx = try XCTUnwrap(shell.calls.firstIndex { $0.contains("commit") })
        XCTAssertGreaterThan(commitIdx, bashExecs[1].offset, "managed toolchains bake before docker commit")
        XCTAssertGreaterThan(bashExecs[0].offset, runIdx)
    }

    func testPrepareManagedFailureAbortsBeforeCommit() async throws {
        // Scripted per call: run ok, ready-probe ok, apt-get probe ok, agent
        // exec ok, managed exec FAILS — no commit must happen, scratch
        // container removed.
        let shell = FakeShell()
        shell.responses = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 1, stdout: "", stderr: "boom"),
        ]
        let preparer = DockerImagePreparer(shell: shell)
        do {
            try await preparer.prepare(
                .init(
                    image: "ubuntu:24.04", target: "kinhin-ci",
                    toolchains: KinhinConfig.ToolchainsConfig(specs: ["node@22"]),
                    hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false
                ))
            XCTFail("expected the bake to fail")
        } catch let error as ImageError {
            guard case .containerProvisioningFailed(let why) = error, why.contains("managed toolchain install failed")
            else {
                return XCTFail("expected managed-toolchain provisioningFailed, got \(error)")
            }
        }
        let argvs = shell.calls
        XCTAssertFalse(argvs.contains { $0.contains("commit") }, "no image is committed when a bake step fails")
        XCTAssertTrue(
            argvs.contains { $0.contains("rm") && $0.contains("--force") }, "the scratch container is cleaned up")
    }

    func testEngineWiresToolchainsIntoDockerRuntime() async throws {
        var config = makeTestConfig()
        config.docker = .init(image: "kinhin-ci-linux", cpus: 2, memoryGB: 4)
        config.toolchains = KinhinConfig.ToolchainsConfig(specs: ["node@22"], shareCache: true)
        let engine = FleetEngine(
            config: config, github: FakeGitHub(), tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            containerShell: FakeShell()
        )
        let runtime = try XCTUnwrap(engine.dockerRuntime)
        let forge = GitHubForge(
            credentials: .github(token: "tok", scope: "acme/widgets"),
            labels: ["kinhin"],
            client: FakeGitHub()
        )
        let route = RepoRoute(
            repo: "acme/widgets", image: "kinhin-ci-linux", ephemeral: true, bootTimeout: 30, cacheMount: true)
        let script = try await runtime.registrationScript(
            forge: forge, token: "tok", name: "c", runnerCount: 1, route: route, labels: nil)
        XCTAssertTrue(script.contains("export NPM_CONFIG_CACHE=\"/var/kinhin-cache/npm\""))
    }
}

/// A shell double that models `docker ps` as real state: `run --name X`
/// creates container X, `rm --force X` removes it, and ps returns the current
/// names — so provision/awaitReady/recovery behave like the real CLI. Other
/// argvs return success.
final class DockerFakingShell: ShellRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var argvs: [[String]] = []
    private var containers: Set<String> = []

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        lock.lock()
        defer { lock.unlock() }
        argvs.append(argv)
        guard argv.first?.hasSuffix("/docker") == true || argv.first == "docker" else {
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        switch argv.dropFirst().first {
        case "ps":
            return ShellResult(exitCode: 0, stdout: containers.sorted().joined(separator: "\n"), stderr: "")
        case "run":
            if let nameIndex = argv.firstIndex(of: "--name"), argv.indices.contains(nameIndex + 1) {
                containers.insert(argv[nameIndex + 1])
            }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        case "start":
            if let name = argv.last { containers.insert(name) }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        case "rm":
            if let name = argv.last { containers.remove(name) }
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
