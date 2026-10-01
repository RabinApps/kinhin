import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

// MARK: - Shared toolchain cache (Linux path, Docker flavor)

final class DockerToolchainCacheTests: XCTestCase {
    private let bin = "/usr/local/bin/docker"

    private func makeRoute(cacheMount: Bool = false) -> RepoRoute {
        RepoRoute(repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 30, cacheMount: cacheMount)
    }

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
                hasGitLabToken: false, hasBuildkiteToken: false, hasAzureDevOpsToken: false))
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
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false
            ))
        // Order: run → ready-probe exec → agent exec → managed exec → commit.
        let runIdx = try XCTUnwrap(shell.calls.firstIndex { $0.contains("run") })
        let bashExecs = shell.calls.enumerated().filter { _, argv in
            argv.contains("exec") && argv.contains("/bin/bash")
        }
        XCTAssertEqual(bashExecs.count, 2, "agent install + managed toolchains: \(shell.calls)")
        let managedExec = shell.calls[bashExecs[1].offset].joined(separator: " ")
        XCTAssertTrue(
            managedExec.contains("mise use --global 'node@22'"), "second exec is the managed toolchain script")
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
                    hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                    hasAzureDevOpsToken: false
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
        let runtime = try XCTUnwrap(engine.runtimesByRuntime[.docker] as? DockerRuntime)
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
final class DockerFakingShell: ShellRunning, Sendable {
    private struct State: Sendable {
        var argvs: [[String]] = []
        var containers: Set<String> = []

        mutating func handle(_ argv: [String]) -> ShellResult {
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
    }

    private let state = Mutex(State())

    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        state.withLock { $0.handle(argv) }
    }

    /// Stdin is recorded as a trailing `<stdin>`, text pair so tests can still
    /// inspect the script an exec delivered.
    func run(_ argv: [String], input: Data, cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        state.withLock { $0.handle(argv + ["<stdin>", String(decoding: input, as: UTF8.self)]) }
    }

    func argvSnapshot() -> [[String]] {
        state.withLock { $0.argvs }
    }
}
