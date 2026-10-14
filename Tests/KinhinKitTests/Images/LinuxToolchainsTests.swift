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
            from: try XCTUnwrap(cfg.projects[0].toolchains), platform: .linux,
            mountPath: ToolchainCacheMount.linuxGuestPath)
    }

    func testLinuxGemInstallChecksEachGemByExitStatus() {
        // Found by `kinhin bench`: the guard was `gem list --local fastlane —exact` (an em dash), and `gem list`
        // exits 0 whether or not the gem is installed, so the install was always skipped.
        var selection = ManagedToolchainSelection()
        selection.gems = ["fastlane", "cocoapods"]
        for root in [true, false] {
            let script = RunnerBootstrap.linuxManagedToolchainsInstallScript(
                selection: selection, mountPath: nil, runsAsRoot: root)
            XCTAssertFalse(script.contains("—"), "no stray em dash in a shell script")
            XCTAssertTrue(script.contains("for g in 'fastlane' 'cocoapods'; do"))
            XCTAssertTrue(script.contains(#"gem list -i "^$g$""#))
            XCTAssertTrue(
                script.contains(root ? "gem install --no-document \"$g\"" : "sudo gem install --no-document \"$g\""))
        }
    }

    /// A tart Linux guest installs as its admin user, so everything that writes root's directories goes through
    /// sudo: the mise bootstrap into /usr/local/bin failed with "Permission denied" (e2e bench on the Tart Linux
    /// lane), and the flutter stack's /opt and /etc/profile.d writes would have too.
    func testANonRootGuestInstallsMiseAndStacksThroughSudo() throws {
        let sel = try linuxSelection(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            projects:
              - pattern: acme/widgets
                toolchains: {specs: ["node@22"], stacks: ["flutter@3.24.0"]}
            """)
        let admin = RunnerBootstrap.linuxManagedToolchainsInstallScript(
            selection: sel, mountPath: nil, runsAsRoot: false)
        XCTAssertTrue(admin.contains("https://mise.run | sudo env MISE_INSTALL_PATH=/usr/local/bin/mise sh"), admin)
        XCTAssertTrue(admin.contains("sudo mkdir -p /opt/flutter && sudo chown"), admin)
        XCTAssertTrue(admin.contains("| sudo tee /etc/profile.d/kinhin-flutter.sh"), admin)
        XCTAssertFalse(admin.contains("<sudo>"), "the placeholder is always filled in")

        let root = RunnerBootstrap.linuxManagedToolchainsInstallScript(selection: sel, mountPath: nil)
        XCTAssertTrue(root.contains("https://mise.run | env MISE_INSTALL_PATH=/usr/local/bin/mise sh"), root)
        XCTAssertTrue(root.contains("  mkdir -p /opt/flutter && chown"), root)
        XCTAssertFalse(root.contains("| sudo "), "a container bake runs as root and has no sudo")
        XCTAssertFalse(root.contains("sudo mkdir"), "a container bake runs as root and has no sudo")
        XCTAssertFalse(root.contains("<sudo>"))
    }

    /// The `kinhin-toolchain` helper is one script for a root container and a tart Linux VM's admin user, so it
    /// decides on sudo when it runs. Rendered for root, `kinhin-toolchain install node@22` in a tart Linux job failed
    /// to install mise (e2e per-job install on the Tart Linux lane).
    func testTheLinuxHelperDecidesOnSudoWhenItRuns() {
        let body = ToolchainHelperEntry.passThroughBody(platform: .linux, mountPath: ToolchainCacheMount.linuxGuestPath)
        XCTAssertTrue(body.contains(#"if [ "$(id -u)" -ne 0 ]"#), "detects a non-root user: \(body)")
        XCTAssertTrue(body.contains("https://mise.run | $SUDO env MISE_INSTALL_PATH=/usr/local/bin/mise sh"), body)
        XCTAssertFalse(body.contains("| sudo env"), "no unconditional sudo: containers have none")
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
            projects:
              - pattern: acme/widgets
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
            projects:
              - pattern: acme/widgets
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
            projects:
              - pattern: acme/widgets
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
            projects:
              - pattern: acme/widgets
                toolchains: {specs: ["dotnet"]}
            """)
        XCTAssertEqual(sel.aptPackages, ["dotnet-sdk-10.0"])
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
            projects:
              - pattern: acme/widgets
                toolchains: {specs: ["node@22"], brew: ["wget"]}
            """)
        XCTAssertTrue(sel.cacheEnvs.contains(ToolchainCacheEnv(variable: "MISE_CACHE_DIR", subdirectory: "mise")))
        XCTAssertFalse(
            sel.cacheEnvs.contains(ToolchainCacheEnv(variable: "HOMEBREW_CACHE", subdirectory: "brew")),
            "no brew install happens on Linux")
    }

    /// mise's rust install cannot use the shared cache on bind/virtiofs mounts
    /// ("Inappropriate ioctl for device"); only rust bypasses it.
    func testLinuxRustInstallsWithoutTheSharedMiseCache() throws {
        let sel = try linuxSelection(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            projects:
              - pattern: acme/widgets
                toolchains: {specs: ["node@22", "rust@stable"]}
            """)
        let script = RunnerBootstrap.linuxManagedToolchainsInstallScript(
            selection: sel, mountPath: ToolchainCacheMount.linuxGuestPath)
        XCTAssertTrue(script.contains("env -u MISE_CACHE_DIR mise use --global 'rust@stable'"), script)
        XCTAssertTrue(script.contains("mise use --global 'node@22'"), "other specs keep the shared cache")
        XCTAssertFalse(script.contains("env -u MISE_CACHE_DIR mise use --global 'node@22'"))
    }

    func testLinuxManagedScriptCoversAptMiseNpmAndGuards() throws {
        let sel = try linuxSelection(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            projects:
              - pattern: acme/widgets
                toolchains: {specs: ["dotnet", "node@22"], stacks: ["vercel"]}
            """)
        let script = RunnerBootstrap.linuxManagedToolchainsInstallScript(
            selection: sel, mountPath: ToolchainCacheMount.linuxGuestPath)
        XCTAssertTrue(script.contains("dpkg-query -W -f='${Status}'"), "guarded apt install: \(script)")
        XCTAssertTrue(script.contains("apt-get install -y --no-install-recommends"))
        XCTAssertTrue(script.contains("dotnet-sdk-10.0"))
        XCTAssertTrue(script.contains("mise.run"), "mise is bootstrapped on Linux (not preinstalled)")
        XCTAssertTrue(script.contains("mise use --global 'node@22'"))
        XCTAssertTrue(script.contains("npm install -g 'vercel'"))
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
            projects:
              - pattern: acme/widgets
                toolchains: {specs: ["node@22"]}
            """)
        let script = RunnerBootstrap.linuxManagedToolchainsInstallScript(selection: sel, mountPath: nil)
        XCTAssertFalse(script.contains("export NPM_CONFIG_CACHE"))
        XCTAssertTrue(script.contains("mise use --global 'node@22'"))
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
                image: "ubuntu:24.04", target: "kinhin-ci-linux", storedTokens: [.github]))
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
                storedTokens: [.github]
            ))
        // Order: run → ready-probe exec → agent exec → managed exec → build.
        let runIdx = try XCTUnwrap(shell.calls.firstIndex { $0.contains("run") })
        let bashExecs = shell.calls.enumerated().filter { _, argv in
            argv.contains("exec") && argv.contains("/bin/bash")
        }
        XCTAssertEqual(bashExecs.count, 2, "agent install + managed toolchains: \(shell.calls)")
        let managedExec = shell.calls[bashExecs[1].offset].joined(separator: " ")
        XCTAssertTrue(
            managedExec.contains("mise use --global 'node@22'"), "second exec is the managed toolchain script")
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
        XCTAssertFalse(argvs.contains { $0.contains("build") }, "no image is built when a bake step fails")
        XCTAssertTrue(
            argvs.contains { $0.contains("delete") && $0.contains("--force") }, "the scratch container is cleaned up")
    }

    func testContainerRunnerMountsCacheOnlyWhenRouteSharesCache() async throws {
        let shell = FakeShell()
        let runtime = AppleContainerRuntime(
            shell: shell, image: "img", cpus: 2, memoryGB: 4, binPath: "/usr/local/bin/container")
        try await runtime.provision(
            id: "kinhin-a", route: RepoRoute(repo: "r", image: "img", ephemeral: true, bootTimeout: 30))
        var runArgv = try XCTUnwrap(shell.calls.last { $0.contains("run") })
        XCTAssertFalse(runArgv.contains("--volume"), "no cacheMount → no bind mount")
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
            binPath: "/usr/local/bin/container"
        )
        let forge = GitHubForge(
            credentials: .github(token: "tok", scope: "acme/widgets"),
            labels: ["self-hosted"],
            client: FakeGitHub()
        )
        let route = RepoRoute(
            repo: "acme/widgets", image: "img", ephemeral: true, bootTimeout: 30, cacheMount: true,
            toolchains: .init(specs: ["node@22", "pnpm"]))
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
            binPath: "/usr/local/bin/container"
        )
        let forge = GitHubForge(
            credentials: .github(token: "tok", scope: "acme/widgets"),
            labels: ["self-hosted"],
            client: FakeGitHub()
        )
        let script = try await runtime.registrationScript(
            forge: forge, token: "tok", name: "c", runnerCount: 1,
            route: RepoRoute(
                repo: "r", image: "img", ephemeral: true, bootTimeout: 30, toolchains: .init(specs: ["node@22"])),
            labels: nil)
        XCTAssertFalse(script.contains("export NPM_CONFIG_CACHE"), "no mount → no cache exports")
    }
}
