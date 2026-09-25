import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Managed toolchains + shared cache: catalog selection, the managed
/// install script, config validation (no-implicit-installs), the cache
/// mount wiring (prepare always; runner VMs opt-in), and the pruner.
final class ToolchainsTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-toolchains-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Config validation

    func testConfigParsesToolchainsSection() throws {
        let cfg = try ConfigLoader.parse(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains:
              specs: ["go@1.23.4", "node@22"]
              brew: ["yamllint"]
              stacks: ["flutter@3.24.0", "vercel"]
              share_cache: true
              cache:
                auto_prune: true
                max_age_days: 14
                max_gb: 20
            """)
        let toolchains = try XCTUnwrap(cfg.toolchains)
        XCTAssertEqual(toolchains.specs, ["go@1.23.4", "node@22"])
        XCTAssertEqual(toolchains.brew, ["yamllint"])
        XCTAssertEqual(toolchains.stacks, ["flutter@3.24.0", "vercel"])
        XCTAssertEqual(toolchains.shareCache, true)
        XCTAssertEqual(toolchains.cache?.maxAgeDays, 14)
        XCTAssertEqual(toolchains.cache?.maxGB, 20)
    }

    func testTemplateHasNoToolchainsSection() throws {
        let cfg = try ConfigLoader.parse(ConfigLoader.template())
        XCTAssertNil(cfg.toolchains, "the starter config must not enable managed toolchains")
    }

    func testDuplicateAndEmptyEntriesRejected() {
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme/widgets"
                labels: ["self-hosted"]
                toolchains: {specs: ["go@1", "go@1"]}
                """))
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme/widgets"
                labels: ["self-hosted"]
                toolchains: {brew: [""]}
                """))
    }

    func testUnknownStackRejectedWithKnownList() {
        let error = self.thrownConfigError(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {stacks: ["flutterish"]}
            """)
        XCTAssertTrue(error.contains("unknown stack 'flutterish'"), error)
        XCTAssertTrue(error.contains("flutter"), "the error should list known stacks: \(error)")
    }

    /// No implicit installs: a stack requiring node fails validation naming
    /// the fix until the user selects node themselves.
    func testStackWithoutNodeRequirementFailsNamingTheFix() {
        let error = self.thrownConfigError(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {stacks: ["vercel"]}
            """)
        XCTAssertTrue(error.contains("requires node"), error)
        XCTAssertTrue(error.contains("node@22"), error)
    }

    func testStackWithExplicitNodeRequirementPasses() throws {
        let cfg = try ConfigLoader.parse(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["node@22"], stacks: ["vercel"]}
            """)
        XCTAssertEqual(cfg.toolchains?.specs, ["node@22"])
    }

    /// Tool-level requirements are validated the same way (pnpm needs node).
    func testNpmToolWithoutNodeRequirementFails() {
        let error = self.thrownConfigError(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["pnpm"]}
            """)
        XCTAssertTrue(error.contains("'pnpm' requires node"), error)
    }

    func testNegativeCacheValuesRejected() {
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme/widgets"
                labels: ["self-hosted"]
                toolchains: {cache: {max_age_days: -5}}
                """))
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                repo: "acme/widgets"
                labels: ["self-hosted"]
                toolchains: {cache: {max_gb: -1}}
                """))
    }

    private func thrownConfigError(_ yaml: String) -> String {
        do {
            _ = try ConfigLoader.parse(yaml)
        } catch let error as ConfigError {
            return error.errorDescription ?? "\(error)"
        } catch {
            return "\(error)"
        }
        XCTFail("expected a config error")
        return ""
    }

    // MARK: Selection resolution

    private func selection(_ yaml: String) throws -> ManagedToolchainSelection {
        let cfg = try ConfigLoader.parse(yaml)
        return ToolchainCatalog.selection(from: try XCTUnwrap(cfg.toolchains), mountPath: "/mnt/cache")
    }

    func testKnownSpecResolvesToMiseWithCacheEnvsAndVerify() throws {
        let sel = try selection(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["go@1.23.4"]}
            """)
        XCTAssertEqual(sel.miseSpecs, ["go@1.23.4"])
        XCTAssertTrue(sel.cacheEnvs.contains(ToolchainCacheEnv(variable: "GOMODCACHE", subdirectory: "go/mod")))
        XCTAssertTrue(sel.verifications.contains("go version"))
    }

    func testUnknownSpecPassesThroughToMise() throws {
        let sel = try selection(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["zig@0.13"]}
            """)
        XCTAssertEqual(sel.miseSpecs, ["zig@0.13"], "long tail: unknown specs go to mise verbatim")
    }

    func testNodeSelectionBringsNpmCache() throws {
        let sel = try selection(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["node@22"]}
            """)
        XCTAssertTrue(sel.cacheEnvs.contains(ToolchainCacheEnv(variable: "NPM_CONFIG_CACHE", subdirectory: "npm")))
    }

    func testNpmToolResolvesAsGlobalInstall() throws {
        let sel = try selection(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["node@22", "pnpm"]}
            """)
        XCTAssertEqual(sel.npmPackages, [.init(name: "pnpm")])
        XCTAssertTrue(
            sel.cacheEnvs.contains(ToolchainCacheEnv(variable: "npm_config_store_dir", subdirectory: "pnpm-store")))
    }

    func testVercelStackResolvesToEASStyleGlobalWithVersion() throws {
        let sel = try selection(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["node@22"], stacks: ["vercel@1.2.3"]}
            """)
        XCTAssertEqual(sel.npmPackages, [.init(name: "vercel", version: "1.2.3")])
        XCTAssertTrue(sel.verifications.contains("vercel --version"))
    }

    func testFlutterStackResolvesToBrewFvmWithCacheAndPin() throws {
        let sel = try selection(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {stacks: ["flutter@3.24.0"]}
            """)
        XCTAssertEqual(sel.brewTaps, ["leoafarias/fvm"])
        XCTAssertTrue(sel.brewFormulas.contains(BrewFormula(name: "fvm", isCask: false)))
        XCTAssertTrue(sel.brewFormulas.contains(BrewFormula(name: "cocoapods", isCask: false)))
        XCTAssertTrue(sel.cacheEnvs.contains(ToolchainCacheEnv(variable: "FVM_CACHE_PATH", subdirectory: "fvm")))
        XCTAssertEqual(sel.stackSteps, ["fvm install 3.24.0", "fvm global 3.24.0"])
    }

    func testDotnetResolvesToCaskWithNugetCache() throws {
        let sel = try selection(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["dotnet"]}
            """)
        XCTAssertEqual(sel.brewFormulas, [BrewFormula(name: "dotnet-sdk", isCask: true)])
        XCTAssertTrue(sel.cacheEnvs.contains(ToolchainCacheEnv(variable: "NUGET_PACKAGES", subdirectory: "nuget")))
        XCTAssertTrue(sel.verifications.contains("dotnet --list-sdks"))
    }

    func testDeduplicatesAcrossSelectionSurfaces() throws {
        let sel = try selection(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["node@22", "pnpm"], brew: ["cocoapods"], stacks: ["react-native"]}
            """)
        let pods = sel.brewFormulas.filter { $0.name == "cocoapods" }
        XCTAssertEqual(pods.count, 1, "cocoapods from brew + react-native stack dedupes")
    }

    // MARK: Managed install script

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
        XCTAssertTrue(exports.contains("if [ -d /mnt/cache ]"), "each export checks the mount")
        XCTAssertTrue(exports.contains("export CARGO_HOME=\"/mnt/cache/cargo\""))
    }

    // MARK: Cache mounts

    func testPrepareAlwaysMountsTheCacheShare() async throws {
        let tart = FakeTart()
        let ssh = FakeSSH()
        let preparer = ImagePreparer(tart: tart, ssh: ssh)
        try await preparer.run(ImagePreparer.Options(hasGitHubToken: true, hasGiteaToken: false))
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

    // MARK: Pruner

    private func makeCache() throws -> (root: URL, pruner: ToolchainCachePruner) {
        let root = scratch.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, ToolchainCachePruner(cacheRoot: root))
    }

    /// Writes a file whose mtime is `ageDays` days in the past.
    private func writeCacheFile(root: URL, relative: String, bytes: Int, ageDays: Double) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        let past = Date().addingTimeInterval(-ageDays * 86_400)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
    }

    func testPruneDeletesOldEntriesButKeepsFreshOnes() throws {
        let (root, pruner) = try makeCache()
        try writeCacheFile(root: root, relative: "npm/old.tar", bytes: 100, ageDays: 40)
        try writeCacheFile(root: root, relative: "npm/new.tar", bytes: 100, ageDays: 1)

        let report = pruner.prune(policy: ToolchainCachePolicy(autoPrune: true, maxAgeDays: 30, maxGB: 0))

        XCTAssertEqual(report.freedBytes, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("npm/old.tar").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("npm/new.tar").path))
    }

    func testPruneEvictsLeastRecentlyUsedBeyondSizeCap() throws {
        let (root, pruner) = try makeCache()
        try writeCacheFile(root: root, relative: "go/mod/old", bytes: 3_000_000_000, ageDays: 20)
        try writeCacheFile(root: root, relative: "npm/pkg", bytes: 3_000_000_000, ageDays: 2)

        // 6 GB total, 4 GB cap → the older entry (3 GB) is evicted.
        let report = pruner.prune(policy: ToolchainCachePolicy(autoPrune: true, maxAgeDays: 0, maxGB: 4))
        XCTAssertEqual(report.freedBytes, 3_000_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("go/mod/old").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("npm/pkg").path))
    }

    func testPruneRespectsGraceWindow() throws {
        let (root, pruner) = try makeCache()
        // Ancient mtime but grace window is computed from the *real* now —
        // write fresh (mid-download simulation): must survive any policy.
        try writeCacheFile(root: root, relative: "fvm/sdk.zip", bytes: 2_000_000_000, ageDays: 0)

        let report = pruner.prune(policy: ToolchainCachePolicy(autoPrune: true, maxAgeDays: 0, maxGB: 1), now: Date())
        XCTAssertTrue(report.entries.isEmpty, "fresh writes are never evicted (grace window)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("fvm/sdk.zip").path))
    }

    func testPruneDryRunReportsWithoutDeleting() throws {
        let (root, pruner) = try makeCache()
        try writeCacheFile(root: root, relative: "npm/old.tar", bytes: 500, ageDays: 90)

        let report = pruner.prune(policy: ToolchainCachePolicy(autoPrune: true, maxAgeDays: 30, maxGB: 0), dryRun: true)
        XCTAssertEqual(report.freedBytes, 500)
        XCTAssertTrue(report.dryRun)
        XCTAssertFalse(report.entries.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("npm/old.tar").path),
            "dry run deletes nothing")
    }

    func testPruneWithoutAutoPruneIsNoopUnlessDryRunRequested() throws {
        let (root, pruner) = try makeCache()
        try writeCacheFile(root: root, relative: "npm/old.tar", bytes: 500, ageDays: 90)

        let report = pruner.prune(policy: ToolchainCachePolicy(autoPrune: false, maxAgeDays: 30, maxGB: 0))
        XCTAssertTrue(report.entries.isEmpty, "auto-prune off → sweep is a no-op")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("npm/old.tar").path))
    }

    func testPruneCleansUpEmptyDirectories() throws {
        let (root, pruner) = try makeCache()
        try writeCacheFile(root: root, relative: "cypress/binary/old.bin", bytes: 100, ageDays: 60)

        _ = pruner.prune(policy: ToolchainCachePolicy(autoPrune: true, maxAgeDays: 30, maxGB: 0))
        var contents: [String] = []
        FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.forEach { item in
            contents.append((item as? URL)?.lastPathComponent ?? "")
        }
        XCTAssertFalse(contents.contains("binary"), "empty dirs left by deletions are removed")
    }

    func testCachePolicyDefaultsFromConfig() {
        XCTAssertEqual(
            ToolchainCachePolicy(from: nil), ToolchainCachePolicy(autoPrune: true, maxAgeDays: 30, maxGB: 50))
        let partial = KinhinConfig.ToolchainsConfig(cache: .init(autoPrune: false, maxAgeDays: 7, maxGB: 0))
        let policy = ToolchainCachePolicy(from: partial)
        XCTAssertEqual(policy, ToolchainCachePolicy(autoPrune: false, maxAgeDays: 7, maxGB: 0))
    }

    // MARK: Versioned stacks

    func testStackSpecParsing() {
        XCTAssertEqual(ToolchainStack.splitSpec("flutter@3.24.0").id, "flutter")
        XCTAssertEqual(ToolchainStack.splitSpec("flutter@3.24.0").version, "3.24.0")
        XCTAssertEqual(ToolchainStack.splitSpec("flutter").id, "flutter")
        XCTAssertNil(ToolchainStack.splitSpec("flutter").version)
        XCTAssertEqual(ToolchainStack.splitSpec("flutter@").id, "flutter")
        XCTAssertNil(ToolchainStack.splitSpec("flutter@").version)
    }

    // MARK: Linux (apple/container) support

    private func linuxSelection(_ yaml: String) throws -> ManagedToolchainSelection {
        let cfg = try ConfigLoader.parse(yaml)
        return ToolchainCatalog.selection(
            from: try XCTUnwrap(cfg.toolchains), platform: .linux, mountPath: ToolchainCacheMount.linuxGuestPath)
    }

    func testLinuxSelectionFiltersMacOSOnlyEntries() throws {
        // flutter (fvm/CocoaPods) and brew tools are macOS-only: skipped with
        // a note, never an error. Cross-platform mise/npm tools remain.
        let sel = try linuxSelection(
            """
            repo: "acme/widgets"
            labels: ["self-hosted"]
            toolchains: {specs: ["node@22", "go@1.23"], brew: ["yamllint", "awscli"], stacks: ["flutter@3.24.0", "vercel"]}
            """)
        XCTAssertTrue(sel.miseSpecs.contains("node@22"))
        XCTAssertTrue(sel.miseSpecs.contains("go@1.23"))
        XCTAssertTrue(sel.npmPackages.contains(.init(name: "vercel")))
        XCTAssertTrue(sel.brewFormulas.isEmpty, "brew formulas never resolve on Linux")
        XCTAssertTrue(sel.aptPackages.isEmpty)
        XCTAssertEqual(Set(sel.skippedEntries), ["yamllint", "awscli", "flutter"])
    }

    func testLinuxDotnetUsesAptInstallerWithNugetCache() throws {
        let sel = try linuxSelection(
            """
            repo: "acme/widgets"
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
            repo: "acme/widgets"
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
            repo: "acme/widgets"
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
        XCTAssertTrue(script.contains("if [ -d /var/kinhin-cache ]; then"))
    }

    func testLinuxManagedScriptSkipsCacheExportsWithoutMount() throws {
        let sel = try linuxSelection(
            """
            repo: "acme/widgets"
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
            .init(image: "ubuntu:24.04", target: "kinhin-ci-linux", hasGitHubToken: true, hasGiteaToken: false))
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
                hasGitHubToken: true, hasGiteaToken: false
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
                    hasGitHubToken: true, hasGiteaToken: false
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
        let runtime = try XCTUnwrap(engine.containerRuntime)
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
