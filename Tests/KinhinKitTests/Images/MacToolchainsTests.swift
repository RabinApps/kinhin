import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The macOS managed-toolchain install script and the shared cache mount
/// wiring (prepare always mounts it; runner VMs only with a project's share_cache).
final class MacToolchainsTests: XCTestCase {
    // MARK: - Managed install script

    private func toolchainsConfig(_ toolchainsYAML: String) throws -> KinhinConfig {
        let indented = toolchainsYAML.split(separator: "\n").map { "      " + $0 }.joined(separator: "\n")
        return try ConfigLoader.parse(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            projects:
              - pattern: acme/widgets
                toolchains:
            \(indented)
            """)
    }

    func testManagedScriptCoversAllSectionsAndGuards() throws {
        let cfg = try self.toolchainsConfig(
            """
              specs: ["node@22", "pnpm"]
              brew: ["yamllint"]
            """)
        let sel = ToolchainCatalog.selection(from: try XCTUnwrap(cfg.projects[0].toolchains), mountPath: "/mnt/cache")
        let script = RunnerBootstrap.managedToolchainsInstallScript(selection: sel, mountPath: "/mnt/cache")

        XCTAssertTrue(script.contains("set -euo pipefail"))
        XCTAssertTrue(script.contains("export NPM_CONFIG_CACHE=\"/mnt/cache/npm\""), script)
        XCTAssertTrue(script.contains("export npm_config_store_dir=\"/mnt/cache/pnpm-store\""), script)
        XCTAssertTrue(script.contains("mise use --global 'node@22'"))
        XCTAssertTrue(script.contains("brew install \"$f\""), "brew installs are guarded")
        XCTAssertTrue(script.contains("brew list --versions \"$f\""), "brew installs are guarded")
        XCTAssertTrue(script.contains("npm install -g 'pnpm'"), "npm globals guarded")
        XCTAssertTrue(script.contains("npm ls -g --depth=0 'pnpm'"), "npm globals guarded")
        XCTAssertTrue(script.contains("corepack enable"), "packageManager-field support")
        XCTAssertTrue(script.contains("yamllint --version"), "verify commands are appended")
        XCTAssertTrue(script.contains("node --version"), "verify commands are appended")
    }

    func testManagedScriptSkipsCacheExportsWithoutMount() throws {
        let cfg = try self.toolchainsConfig(
            """
              specs: ["node@22"]
            """)
        let sel = ToolchainCatalog.selection(from: try XCTUnwrap(cfg.projects[0].toolchains))
        let script = RunnerBootstrap.managedToolchainsInstallScript(selection: sel, mountPath: nil)
        let exports = script.split(separator: "\n").filter { $0.hasPrefix("export ") }
        XCTAssertTrue(
            exports.allSatisfy { $0.contains("PATH=") || $0.contains("HOMEBREW_") },
            "no mount → no cache exports (defaults apply); only the PATH/Homebrew setup remains")
        XCTAssertTrue(script.contains("mise use --global 'node@22'"))
    }

    /// ssh starts a bare shell (no login profile), so the script must put brew and
    /// mise on PATH itself, before the first use of either.
    /// rustup cannot write into CARGO_HOME on the virtiofs share, so the catalog must not redirect it.
    func testRustDoesNotRedirectCargoHomeOntoTheSharedCache() throws {
        let rust = try XCTUnwrap(ToolchainCatalog.tool(id: "rust"))
        XCTAssertFalse(rust.cacheEnvs.contains { $0.variable == "CARGO_HOME" })
    }

    /// mise's rust install cannot use the virtiofs MISE_CACHE_DIR; only rust bypasses it.
    func testRustInstallsWithoutTheSharedMiseCache() throws {
        let cfg = try self.toolchainsConfig(
            """
              specs: ["node@22", "rust@stable"]
            """)
        let sel = ToolchainCatalog.selection(from: try XCTUnwrap(cfg.projects[0].toolchains))
        let script = RunnerBootstrap.managedToolchainsInstallScript(selection: sel, mountPath: "/mnt/cache")
        XCTAssertTrue(script.contains("env -u MISE_CACHE_DIR mise use --global 'rust@stable'"), script)
        XCTAssertTrue(script.contains("mise use --global 'node@22'"), "other specs keep the shared cache")
        XCTAssertFalse(script.contains("env -u MISE_CACHE_DIR mise use --global 'node@22'"))
    }

    func testManagedScriptPutsHomebrewAndMiseOnPathFirst() throws {
        let cfg = try self.toolchainsConfig(
            """
              specs: ["node@22"]
            """)
        let sel = ToolchainCatalog.selection(from: try XCTUnwrap(cfg.projects[0].toolchains))
        let script = RunnerBootstrap.managedToolchainsInstallScript(selection: sel, mountPath: nil)
        let path = try XCTUnwrap(script.range(of: "export PATH=\"$HOME/.local/share/mise/shims:/opt/homebrew/bin"))
        let mise = try XCTUnwrap(script.range(of: "mise use --global"))
        XCTAssertLessThan(path.lowerBound, mise.lowerBound)
        XCTAssertTrue(script.contains("/opt/homebrew/sbin"), "brew stays on PATH, behind the shims")
    }

    func testCacheEnvExportsAreGuardedOnMountPresence() {
        let exports = RunnerBootstrap.cacheEnvExports(
            cacheEnvs: [ToolchainCacheEnv(variable: "CARGO_HOME", subdirectory: "cargo")],
            mountPath: "/mnt/cache"
        )
        XCTAssertTrue(exports.contains("if [ -d \"/mnt/cache\" ]"), "each export checks the mount")
        XCTAssertTrue(exports.contains("export CARGO_HOME=\"/mnt/cache/cargo\""))
    }

    /// The macOS guest mount ("/Volumes/My Shared Files/…") has spaces: an
    /// unquoted `[ -d … ]` errors out and silently skips every export.
    func testCacheEnvExportsHandleMountPathsWithSpaces() async throws {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin cache \(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: mount) }  // temp dir; leftovers are harmless
        let exports = RunnerBootstrap.cacheEnvExports(
            cacheEnvs: [ToolchainCacheEnv(variable: "CARGO_HOME", subdirectory: "cargo")], mountPath: mount)
        let result = try await Shell().run(["/bin/bash", "-c", exports + "\nprintf '%s' \"$CARGO_HOME\""])
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertEqual(result.stdout, mount + "/cargo")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
    }

    // MARK: - Cache mounts

    func testPrepareAlwaysMountsTheCacheShare() async throws {
        let tart = FakeTart()
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        try await preparer.run(
            ImagePreparer.Options(
                hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false, hasBuildkiteToken: false,
                hasAzureDevOpsToken: false))
        XCTAssertEqual(tart.runMounts.count, 1)
        XCTAssertEqual(
            tart.runMounts[0], [ToolchainCacheMount.tartDirectorySpec], "prepare shares the host cache unconditionally")
    }

    func testRunnerVMsMountCacheOnlyWhenShareCacheIsOn() async throws {
        let tart = FakeTart()
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 })
        // Default route: no mount.
        try await runtime.provision(
            id: "kinhin-a", route: RepoRoute(repo: "r", image: "tahoe-base", ephemeral: true, bootTimeout: 300))
        XCTAssertEqual(tart.runMounts.last, [], "share_cache off → no virtiofs mount")
        // Opt-in route: mount.
        try await runtime.provision(
            id: "kinhin-b",
            route: RepoRoute(repo: "r", image: "tahoe-base", ephemeral: true, bootTimeout: 300, cacheMount: true))
        XCTAssertEqual(tart.runMounts.last, [ToolchainCacheMount.tartDirectorySpec], "share_cache on → cache mounted")
    }

    func testSharesToolchainCacheComesFromProjects() throws {
        let cfg = try ConfigLoader.parse(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            projects:
              - pattern: acme/widgets
                share_cache: true
            """)
        XCTAssertTrue(cfg.sharesToolchainCache)
        let plain = try ConfigLoader.parse(
            """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
            labels: ["self-hosted"]
            """)
        XCTAssertFalse(plain.sharesToolchainCache)
        XCTAssertFalse(RepoRoute.from(config: plain).cacheMount, "the route's mount is passed in, never derived")
        XCTAssertTrue(RepoRoute.from(config: cfg, cacheMount: true).cacheMount)
    }

    func testScopedRouteMountsOnlyItsCacheSubdirectory() async throws {
        let tart = FakeTart()
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 })
        try await runtime.provision(
            id: "kinhin-c",
            route: RepoRoute(
                repo: "r", image: "p-img", ephemeral: true, bootTimeout: 300, cacheMount: true, cacheScope: "p-img"))
        XCTAssertEqual(tart.runMounts.last, [ToolchainCacheMount.tartDirectorySpec(scope: "p-img")])
    }

    func testRegistrationScriptPrefixesCacheExportsWhenMounted() async throws {
        let tart = FakeTart()
        let runtime = TartRuntime(tart: tart, bootTimeout: { 300 })
        let forge = GitHubForge(
            credentials: .github(token: "tok", scope: "acme/widgets"),
            labels: ["self-hosted"],
            client: FakeGitHub()
        )
        let route = RepoRoute(
            repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 300, cacheMount: true,
            toolchains: .init(specs: ["node@22", "pnpm"]))
        let script = try await runtime.registrationScript(
            forge: forge, token: "tok", name: "vm", runnerCount: 1, route: route, labels: nil)
        XCTAssertTrue(script.contains("export NPM_CONFIG_CACHE"), "registration script exports cache envs")
        XCTAssertTrue(script.contains("uname -s"), "the guest picks its own cache root (macOS or Linux base VM)")
        XCTAssertTrue(script.contains("mount -t virtiofs"), "Linux guests mount the share by hand")
        XCTAssertTrue(script.contains("config.sh --url"), "registration script itself still present")
        XCTAssertTrue(
            script.range(of: "export NPM_CONFIG_CACHE")!.lowerBound < script.range(of: "config.sh --url")!.lowerBound,
            "exports come first")
    }
}
