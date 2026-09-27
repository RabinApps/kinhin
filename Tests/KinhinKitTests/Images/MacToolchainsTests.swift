import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// The macOS managed-toolchain install script and the shared cache mount
/// wiring (prepare always mounts it; runner VMs only with share_cache).
final class MacToolchainsTests: XCTestCase {
    // MARK: - Managed install script

    private func toolchainsConfig(_ toolchainsYAML: String) throws -> KinhinConfig {
        try ConfigLoader.parse(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains:
            \(toolchainsYAML)
            """)
    }

    func testManagedScriptCoversAllSectionsAndGuards() throws {
        let cfg = try self.toolchainsConfig(
            """
              specs: ["node@22", "pnpm"]
              brew: ["yamllint"]
            """)
        let sel = ToolchainCatalog.selection(from: try XCTUnwrap(cfg.toolchains), mountPath: "/mnt/cache")
        let script = RunnerBootstrap.managedToolchainsInstallScript(selection: sel, mountPath: "/mnt/cache")

        XCTAssertTrue(script.contains("set -euo pipefail"))
        XCTAssertTrue(script.contains("export NPM_CONFIG_CACHE=\"/mnt/cache/npm\""), script)
        XCTAssertTrue(script.contains("export npm_config_store_dir=\"/mnt/cache/pnpm-store\""), script)
        XCTAssertTrue(script.contains("mise use --global node@22"))
        XCTAssertTrue(script.contains("brew install \"$f\""), "brew installs are guarded")
        XCTAssertTrue(script.contains("brew list --versions \"$f\""), "brew installs are guarded")
        XCTAssertTrue(script.contains("npm install -g pnpm"), "npm globals guarded")
        XCTAssertTrue(script.contains("npm ls -g --depth=0 pnpm"), "npm globals guarded")
        XCTAssertTrue(script.contains("corepack enable"), "packageManager-field support")
        XCTAssertTrue(script.contains("yamllint --version"), "verify commands are appended")
        XCTAssertTrue(script.contains("node --version"), "verify commands are appended")
    }

    func testManagedScriptSkipsCacheExportsWithoutMount() throws {
        let cfg = try self.toolchainsConfig(
            """
              specs: ["node@22"]
            """)
        let sel = ToolchainCatalog.selection(from: try XCTUnwrap(cfg.toolchains))
        let script = RunnerBootstrap.managedToolchainsInstallScript(selection: sel, mountPath: nil)
        XCTAssertFalse(script.contains("export "), "no mount → no cache exports (defaults apply)")
        XCTAssertTrue(script.contains("mise use --global node@22"))
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
        try await preparer.run(ImagePreparer.Options(hasGitHubToken: true, hasGiteaToken: false, hasGitLabToken: false))
        XCTAssertEqual(tart.runMounts.count, 1)
        XCTAssertEqual(
            tart.runMounts[0], [ToolchainCacheMount.guestPath], "prepare shares the host cache unconditionally")
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
        XCTAssertEqual(tart.runMounts.last, [ToolchainCacheMount.guestPath], "share_cache on → cache mounted")
    }

    func testRepoRouteCarriesShareCacheFromConfig() throws {
        let cfg = try ConfigLoader.parse(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {share_cache: true}
            """)
        XCTAssertEqual(RepoRoute.from(config: cfg).cacheMount, true)
        let plain = try ConfigLoader.parse(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            """)
        XCTAssertEqual(RepoRoute.from(config: plain).cacheMount, false)
    }

    func testRegistrationScriptPrefixesCacheExportsWhenMounted() async throws {
        let tart = FakeTart()
        let runtime = TartRuntime(
            tart: tart,
            bootTimeout: { 300 },
            toolchainsConfig: {
                try? ConfigLoader.parse(
                    """
                    repo: "acme/widgets"
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
        let route = RepoRoute(
            repo: "acme/widgets", image: "tahoe-base", ephemeral: true, bootTimeout: 300, cacheMount: true)
        let script = try await runtime.registrationScript(
            forge: forge, token: "tok", name: "vm", runnerCount: 1, route: route, labels: nil)
        XCTAssertTrue(script.contains("export NPM_CONFIG_CACHE"), "registration script exports cache envs")
        XCTAssertTrue(script.contains("config.sh --url"), "registration script itself still present")
        XCTAssertTrue(
            script.range(of: "export NPM_CONFIG_CACHE")!.lowerBound < script.range(of: "config.sh --url")!.lowerBound,
            "exports come first")
    }
}
