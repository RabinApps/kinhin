import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `toolchains:` config validation (no implicit installs) and how the
/// catalog resolves a selection into install steps, cache envs and pins.
final class ToolchainSelectionTests: XCTestCase {
    // MARK: - Config validation

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

    // MARK: - Selection resolution

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

    // MARK: - Versioned stacks

    func testStackSpecParsing() {
        XCTAssertEqual(ToolchainStack.splitSpec("flutter@3.24.0").id, "flutter")
        XCTAssertEqual(ToolchainStack.splitSpec("flutter@3.24.0").version, "3.24.0")
        XCTAssertEqual(ToolchainStack.splitSpec("flutter").id, "flutter")
        XCTAssertNil(ToolchainStack.splitSpec("flutter").version)
        XCTAssertEqual(ToolchainStack.splitSpec("flutter@").id, "flutter")
        XCTAssertNil(ToolchainStack.splitSpec("flutter@").version)
    }
}
