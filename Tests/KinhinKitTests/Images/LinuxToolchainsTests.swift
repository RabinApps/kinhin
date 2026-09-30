import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Managed toolchains on Linux (apple/container): selection filtering,
/// the apt/mise install script, and the container cache mounts.
final class LinuxToolchainsTests: XCTestCase {
    // MARK: - Linux (apple/container) support

    private func linuxSelection(_ yaml: String) throws -> ManagedToolchainSelection {
        let cfg = try ConfigLoader.parse(yaml)
        return ToolchainCatalog.selection(
            from: try XCTUnwrap(cfg.toolchains), platform: .linux, mountPath: ToolchainCacheMount.linuxGuestPath)
    }

    func testLinuxSelectionFiltersMacOSOnlyEntries() throws {
        // Raw brew formulas and macOS-only stacks are skipped with a note,
        // never an error. Cross-platform mise/npm tools, catalog tools with a
        // Linux installer (yamllint via apt, awscli via mise) and stacks with
        // a Linux recipe (flutter) remain.
        let sel = try linuxSelection(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["node@22", "go@1.23"], brew: ["yamllint", "awscli", "wget"], stacks: ["flutter@3.24.0", "vercel", "react-native"]}
            """)
        XCTAssertTrue(sel.miseSpecs.contains("node@22"))
        XCTAssertTrue(sel.miseSpecs.contains("go@1.23"))
        XCTAssertTrue(sel.npmPackages.contains(.init(name: "vercel")))
        XCTAssertTrue(sel.brewFormulas.isEmpty, "brew formulas never resolve on Linux")
        XCTAssertEqual(Set(sel.skippedEntries), ["wget", "react-native"])
        XCTAssertTrue(sel.aptPackages.contains("yamllint"))
        XCTAssertTrue(sel.miseSpecs.contains("awscli@latest"))
        XCTAssertTrue(sel.aptPackages.contains("git"), "flutter's prerequisites come from apt")
    }

    /// Flutter installs on Linux from git (no snap, no Homebrew/fvm), pinned
    /// to the configured version, on PATH for job shells, and verified.
    func testLinuxFlutterInstallsFromGit() throws {
        let sel = try linuxSelection(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {stacks: ["flutter@3.24.0"]}
            """)
        XCTAssertTrue(
            Set(["curl", "git", "unzip", "xz-utils", "zip", "libglu1-mesa"]).isSubset(of: sel.aptPackages),
            "Flutter's documented Linux prerequisites")
        XCTAssertTrue(
            Set(["clang", "cmake", "ninja-build", "pkg-config", "libgtk-3-dev", "liblzma-dev"])
                .isSubset(of: sel.aptPackages),
            "the toolchain `flutter build linux` needs")
        XCTAssertTrue(sel.brewFormulas.isEmpty)
        XCTAssertTrue(sel.brewTaps.isEmpty)
        XCTAssertTrue(sel.skippedEntries.isEmpty)
        let steps = sel.stackSteps.joined(separator: "\n")
        XCTAssertTrue(steps.contains("flutter_ref='3.24.0'"), steps)
        XCTAssertTrue(
            steps.contains("git clone --filter=blob:none https://github.com/flutter/flutter.git /opt/flutter"))
        XCTAssertTrue(steps.contains("/etc/profile.d/kinhin-flutter.sh"))
        XCTAssertTrue(steps.contains("flutter precache --universal --web --linux"))
        XCTAssertFalse(steps.contains("snap"), "no snap")
        XCTAssertFalse(steps.contains("fvm"), "fvm is the macOS path")
        XCTAssertEqual(sel.verifications, ["/opt/flutter/bin/flutter --version"])

        let script = RunnerBootstrap.linuxManagedToolchainsInstallScript(
            selection: sel, mountPath: ToolchainCacheMount.linuxGuestPath)
        let apt = try XCTUnwrap(script.range(of: "apt-get install"))
        let clone = try XCTUnwrap(script.range(of: "git clone --filter=blob:none"))
        XCTAssertLessThan(apt.lowerBound, clone.lowerBound, "prerequisites install before the clone")
    }

    func testLinuxFlutterDefaultsToTheStableChannel() throws {
        let sel = try linuxSelection(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {stacks: ["flutter"]}
            """)
        XCTAssertTrue(sel.stackSteps.joined().contains("flutter_ref='stable'"))
    }

    func testLinuxFlutterVersionIsShellQuoted() throws {
        // A pinned version lands in a shell script: it must never be able to
        // break out of its quotes (' becomes '\'' inside single quotes).
        var cfg = KinhinConfig.ToolchainsConfig()
        cfg.stacks = ["flutter@1'; touch /tmp/pwned; echo '"]
        let sel = ToolchainCatalog.selection(from: cfg, platform: .linux, mountPath: nil)
        let steps = sel.stackSteps.joined()
        XCTAssertTrue(steps.contains(#"flutter_ref='1'\''; touch /tmp/pwned; echo '\'''"#), steps)
    }

    func testLinuxDotnetUsesAptInstallerWithNugetCache() throws {
        let sel = try linuxSelection(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["dotnet"]}
            """)
        XCTAssertEqual(sel.aptPackages, ["dotnet-sdk-8.0"])
        XCTAssertTrue(sel.cacheEnvs.contains(ToolchainCacheEnv(variable: "NUGET_PACKAGES", subdirectory: "nuget")))
        XCTAssertTrue(sel.verifications.contains("dotnet --list-sdks"))
    }

    func testLinuxSelectionAutoInjectsMiseCacheAndSkipsHomebrewCache() throws {
        let sel = try linuxSelection(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["node@22"], brew: ["wget"]}
            """)
        XCTAssertTrue(sel.cacheEnvs.contains(ToolchainCacheEnv(variable: "MISE_CACHE_DIR", subdirectory: "mise")))
        XCTAssertFalse(
            sel.cacheEnvs.contains(ToolchainCacheEnv(variable: "HOMEBREW_CACHE", subdirectory: "brew")),
            "no brew install happens on Linux")
    }

    func testLinuxManagedScriptCoversAptMiseNpmAndGuards() throws {
        let sel = try linuxSelection(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["dotnet", "node@22"], stacks: ["vercel"]}
            """)
        let script = RunnerBootstrap.linuxManagedToolchainsInstallScript(
            selection: sel, mountPath: ToolchainCacheMount.linuxGuestPath)
        XCTAssertTrue(script.contains("dpkg-query -W -f='${Status}'"), "guarded apt install: \(script)")
        XCTAssertTrue(script.contains("apt-get install -y --no-install-recommends"))
        XCTAssertTrue(script.contains("dotnet-sdk-8.0"))
        XCTAssertTrue(script.contains("mise.run"), "mise is bootstrapped on Linux (not preinstalled)")
        XCTAssertTrue(script.contains("mise use --global node@22"))
        XCTAssertTrue(script.contains("npm install -g vercel"))
        XCTAssertTrue(
            script.contains("export NPM_CONFIG_CACHE=\"/var/kinhin-cache/npm\""),
            "cache exports point at the Linux guest path")
        XCTAssertTrue(script.contains("export NUGET_PACKAGES=\"/var/kinhin-cache/nuget\""))
        XCTAssertTrue(script.contains("dotnet --list-sdks"), "verify commands still gate the bake")
        // Guarded exports: a missing mount must not fail the script.
        XCTAssertTrue(script.contains("if [ -d \"/var/kinhin-cache\" ]; then"))
    }

    func testLinuxManagedScriptSkipsCacheExportsWithoutMount() throws {
        let sel = try linuxSelection(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["node@22"]}
            """)
        let script = RunnerBootstrap.linuxManagedToolchainsInstallScript(selection: sel, mountPath: nil)
        XCTAssertFalse(script.contains("export NPM_CONFIG_CACHE"))
        XCTAssertTrue(script.contains("mise use --global node@22"))
    }

    func testLinuxCacheMountVolumeSpecAndConstants() {
        XCTAssertEqual(ToolchainCacheMount.linuxGuestPath, "/var/kinhin-cache")
        let spec = ToolchainCacheMount.volumeSpec(host: "/Users/me/Library/cache")
        XCTAssertEqual(spec, "/Users/me/Library/cache:/var/kinhin-cache")
    }

    func testContainerPrepareAlwaysBindMountsTheCache() async throws {
        let shell = FakeShell()
        let preparer = ContainerImagePreparer(shell: shell)
        try await preparer.prepare(
            .init(
                image: "ubuntu:24.04", target: "kinhin-ci-linux", hasGitHubToken: true, hasGiteaToken: false,
                hasGitLabToken: false, hasBuildkiteToken: false, hasAzureDevOpsToken: false))
        let runArgv = try XCTUnwrap(shell.calls.first { $0.contains("run") })
        XCTAssertTrue(runArgv.contains("--volume"), "prepare bind-mounts the host cache unconditionally: \(runArgv)")
        XCTAssertTrue(runArgv.contains(ToolchainCacheMount.volumeSpec(host: Paths.toolchainCache.path)))
    }

    func testContainerPrepareBakesManagedToolchainsBeforeBuild() async throws {
        let shell = FakeShell()
        let preparer = ContainerImagePreparer(shell: shell)
        try await preparer.prepare(
            .init(
                image: "ubuntu:24.04", target: "kinhin-ci-linux",
                toolchains: KinhinConfig.ToolchainsConfig(specs: ["node@22"]),
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false
            ))
        // Order: run → ready-probe exec → agent exec → managed exec → build.
        let runIdx = try XCTUnwrap(shell.calls.firstIndex { $0.contains("run") })
        let bashExecs = shell.calls.enumerated().filter { _, argv in
            argv.contains("exec") && argv.contains("/bin/bash")
        }
        XCTAssertEqual(bashExecs.count, 2, "agent install + managed toolchains: \(shell.calls)")
        let managedExec = shell.calls[bashExecs[1].offset].joined(separator: " ")
        XCTAssertTrue(managedExec.contains("mise use --global node@22"), "second exec is the managed toolchain script")
        let buildIdx = try XCTUnwrap(shell.calls.firstIndex { $0.contains("build") })
        XCTAssertGreaterThan(buildIdx, bashExecs[1].offset, "managed toolchains bake before container build")
        XCTAssertGreaterThan(bashExecs[0].offset, runIdx)
    }

    func testContainerPrepareManagedFailureAbortsBeforeBuild() async throws {
        // Scripted per call: run ok, ready-probe ok, apt-get probe ok, agent
        // exec ok, managed exec FAILS (probes after that never happen — the
        // error throws).
        let shell = FakeShell()
        shell.responses = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 1, stdout: "", stderr: "boom"),
        ]
        let preparer = ContainerImagePreparer(shell: shell)
        do {
            try await preparer.prepare(
                .init(
                    image: "ubuntu:24.04", target: "kinhin-ci-linux",
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
        XCTAssertFalse(argvs.contains { $0.contains("build") }, "no image is built when a bake step fails")
        XCTAssertTrue(
            argvs.contains { $0.contains("delete") && $0.contains("--force") }, "the scratch container is cleaned up")
    }

    func testContainerRunnerMountsCacheOnlyWhenShareCacheIsOn() async throws {
        let shell = FakeShell()
        let runtime = AppleContainerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4, binPath: "/usr/local/bin/container")
        try await runtime.provision(
            id: "kinhin-a", route: RepoRoute(repo: "r", image: "img", ephemeral: true, bootTimeout: 30))
        var runArgv = try XCTUnwrap(shell.calls.last { $0.contains("run") })
        XCTAssertFalse(runArgv.contains("--volume"), "share_cache off → no bind mount")
        try await runtime.provision(
            id: "kinhin-b",
            route: RepoRoute(repo: "r", image: "img", ephemeral: true, bootTimeout: 30, cacheMount: true))
        runArgv = try XCTUnwrap(shell.calls.last { $0.contains("run") })
        XCTAssertTrue(runArgv.contains("--volume"))
        XCTAssertTrue(runArgv.contains(ToolchainCacheMount.volumeSpec(host: Paths.toolchainCache.path)))
    }

    func testContainerRegistrationScriptPrefixesLinuxCacheExports() async throws {
        let shell = FakeShell()
        let runtime = AppleContainerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4,
            binPath: "/usr/local/bin/container",
            toolchainsConfig: {
                try? ConfigLoader.parse(
                    """
                    accounts:
                      - name: github
                        forge: github
                        scope: "acme/widgets"
                    labels: ["self-hosted"]
                    toolchains: {specs: ["node@22", "pnpm"]}
                    """
                ).toolchains
            }
        )
        let forge = GitHubForge(
            credentials: .github(token: "tok", scope: "acme/widgets"),
            labels: ["self-hosted"],
            client: FakeGitHub()
        )
        let route = RepoRoute(repo: "acme/widgets", image: "img", ephemeral: true, bootTimeout: 30, cacheMount: true)
        let script = try await runtime.registrationScript(
            forge: forge, token: "tok", name: "c", runnerCount: 1, route: route, labels: nil)
        XCTAssertTrue(script.contains("export NPM_CONFIG_CACHE=\"/var/kinhin-cache/npm\""))
        XCTAssertTrue(script.contains("export npm_config_store_dir=\"/var/kinhin-cache/pnpm-store\""))
        XCTAssertTrue(script.contains("/opt/actions-runner"), "registration script itself still present")
        XCTAssertTrue(
            script.range(of: "export NPM_CONFIG_CACHE")!.lowerBound < script.range(of: "config.sh --url")!.lowerBound,
            "exports come first")
    }

    func testContainerRegistrationScriptWithoutMountHasNoExports() async throws {
        let runtime = AppleContainerRuntime(
            shell: FakeShell(), image: "img", cpus: 2, memoryGB: 4,
            binPath: "/usr/local/bin/container",
            toolchainsConfig: { KinhinConfig.ToolchainsConfig(specs: ["node@22"]) }
        )
        let forge = GitHubForge(
            credentials: .github(token: "tok", scope: "acme/widgets"),
            labels: ["self-hosted"],
            client: FakeGitHub()
        )
        let script = try await runtime.registrationScript(
            forge: forge, token: "tok", name: "c", runnerCount: 1,
            route: RepoRoute(repo: "r", image: "img", ephemeral: true, bootTimeout: 30), labels: nil)
        XCTAssertFalse(script.contains("export NPM_CONFIG_CACHE"), "no mount → no cache exports")
    }

    func testEngineWiresToolchainsIntoContainerRuntime() async throws {
        let shell = ContainerFakingShell()
        var config = makeTestConfig()
        config.container = .init(image: "kinhin-ci-linux", cpus: 2, memoryGB: 4)
        config.toolchains = KinhinConfig.ToolchainsConfig(specs: ["node@22"], shareCache: true)
        let engine = FleetEngine(
            config: config, github: FakeGitHub(), tart: FakeTart(),
            store: makeTestStore(), ssh: FakeSSH(), host: testHost,
            containerShell: shell
        )
        // The engine passes its config into the container runtime; verify via
        // the runtime's registration script containing the Linux cache envs.
        let runtime = try XCTUnwrap(engine.runtimesByRuntime[.appleContainer] as? AppleContainerRuntime)
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
