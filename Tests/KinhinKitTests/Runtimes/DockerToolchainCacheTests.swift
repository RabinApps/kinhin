import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

// MARK: - Shared toolchain cache (Linux path, Docker flavor)

final class DockerToolchainCacheTests: XCTestCase {
    private let bin = "/usr/local/bin/docker"

    private func makeRoute(cacheMount: Bool = false, toolchains: KinhinConfig.ToolchainsConfig? = nil) -> RepoRoute {
        RepoRoute(
            repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 30, cacheMount: cacheMount,
            toolchains: toolchains)
    }

    func testProvisionMountsCacheOnlyWhenRouteSharesCache() async throws {
        let shell = FakeShell()
        let runtime = DockerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: bin
        )
        try await runtime.provision(id: "kinhin-a", route: makeRoute())
        let runArgvA = try XCTUnwrap(shell.calls.first { $0.contains("run") && $0.contains("kinhin-a") })
        XCTAssertFalse(runArgvA.contains("--volume"), "no cacheMount → no bind mount")

        try await runtime.provision(id: "kinhin-b", route: makeRoute(cacheMount: true))
        let runArgvB = try XCTUnwrap(shell.calls.first { $0.contains("run") && $0.contains("kinhin-b") })
        XCTAssertTrue(runArgvB.contains("--volume"))
        XCTAssertTrue(runArgvB.contains(ToolchainCacheMount.volumeSpec(host: Paths.toolchainCache.path)))
        // The route's image names a tart VM image; a Linux runtime always starts its own configured image.
        XCTAssertTrue(runArgvA.contains("img"), "the runtime's configured image is what gets started")
        XCTAssertFalse(runArgvA.contains("tahoe-base"))
        XCTAssertTrue(runArgvB.contains("img"))
    }

    /// A project-scoped route mounts only that project's cache subdirectory,
    /// as tart does, so projects sharing a Linux runtime never see each other's downloads.
    func testProvisionMountsOnlyTheProjectScopedCache() async throws {
        let shell = FakeShell()
        let runtime = DockerRuntime(shell: shell, image: "img", cpus: 2, memoryGB: 4, binPath: bin)
        let route = RepoRoute(
            repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 30, cacheMount: true,
            cacheScope: "proj-key")
        try await runtime.provision(id: "kinhin-s", route: route)
        let runArgv = try XCTUnwrap(shell.calls.first { $0.contains("run") && $0.contains("kinhin-s") })
        let scoped = Paths.toolchainCache.appendingPathComponent("proj-key", isDirectory: true).path
        XCTAssertTrue(runArgv.contains(ToolchainCacheMount.volumeSpec(host: scoped)))
        XCTAssertFalse(
            runArgv.contains(ToolchainCacheMount.volumeSpec(host: Paths.toolchainCache.path)),
            "a scoped project must not get the whole cache")
    }

    func testRegistrationScriptPrefixesLinuxCacheExportsWhenMounted() async throws {
        let runtime = DockerRuntime(
            shell: FakeShell(), image: "img", cpus: 2, memoryGB: 4,
            binPath: bin
        )
        let github = GitHubForge(
            credentials: .github(token: "tok", scope: "acme/widgets"),
            labels: ["kinhin"],
            client: FakeGitHub()
        )
        let script = try await runtime.registrationScript(
            forge: github, token: "RT", name: "kinhin-1", runnerCount: 1,
            route: makeRoute(cacheMount: true, toolchains: .init(specs: ["node@22", "pnpm"])), labels: nil
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
            binPath: bin
        )
        let github = GitHubForge(
            credentials: .github(token: "tok", scope: "acme/widgets"),
            labels: ["kinhin"],
            client: FakeGitHub()
        )
        let script = try await runtime.registrationScript(
            forge: github, token: "RT", name: "kinhin-1", runnerCount: 1,
            route: makeRoute(toolchains: .init(specs: ["node@22"])), labels: nil
        )
        XCTAssertFalse(script.contains("export NPM_CONFIG_CACHE"), "no mount → no cache exports")
    }

    func testPrepareAlwaysBindMountsTheCache() async throws {
        let shell = FakeShell()
        let preparer = DockerImagePreparer(shell: shell)
        try await preparer.prepare(
            .init(
                image: "ubuntu:24.04", target: "kinhin-ci", storedTokens: [.github]))
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
                storedTokens: [.github]
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
                    storedTokens: [.github]
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
}
