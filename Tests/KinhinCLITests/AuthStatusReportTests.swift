import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin

/// The `kinhin auth status --json` contract: per-forge stored-token state,
/// masked prefixes, config-aware scope/instance fields, and the allGood /
/// exit-code biconditional. Pure reporter — no Keychain, network, or config
/// file is touched; the CLI-level `--json` flow runs through the same
/// injected AuthEnvironment the other auth tests use.
final class AuthStatusReportTests: XCTestCase {
    private static func config(repo: String = "acme/widgets", gitea: Bool = false) -> KinhinConfig {
        var cfg = KinhinConfig.default
        if !repo.isEmpty {
            cfg.accounts = [AccountConfig(name: "github", forge: .github, scope: repo)]
        }
        if gitea {
            cfg.accounts.append(
                AccountConfig(
                    name: "gitea", forge: .gitea, scope: "acme", instance: "https://gitea.example.com",
                    labels: ["macos:host"]))
        }
        return cfg
    }

    private func report(
        stored: [ForgeID: String] = [:],
        config: KinhinConfig? = nil
    ) -> AuthStatusReport {
        // Both token sources inject the same map so no test touches the real
        // Keychain (the account rows use `loadAccount`).
        AuthStatusReporter.report(config: config, load: { stored[$0] }, loadAccount: { forge, _ in stored[forge] })
    }

    /// The default fixture, for call sites that need a working config.
    private func reportWithDefaultConfig(stored: [ForgeID: String] = [:]) -> AuthStatusReport {
        report(stored: stored, config: Self.config())
    }

    // MARK: - Contract shape

    func testOneForgeEntryPerForgeInStableOrder() {
        let report = report(config: Self.config(gitea: true))
        XCTAssertEqual(
            report.forges.map(\.id), ["github", "gitea", "forgejo"], "github first — ForgeID order is the API order")
    }

    func testJSONRoundTripPreservesTheContract() throws {
        let report = report(stored: [.github: "ghp_x", .gitea: "gt_y"], config: Self.config(gitea: true))
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(AuthStatusReport.self, from: data)
        XCTAssertEqual(decoded, report, "the emitted JSON is the documented contract — it must decode back exactly")
    }

    // MARK: - GitHub entries

    func testGitHubStoredAndConfiguredCarriesMaskedPrefixAndScope() {
        let forge = reportWithDefaultConfig(stored: [.github: "ghp_secret1234"]).forges[0]
        XCTAssertEqual(forge.id, "github")
        XCTAssertTrue(forge.stored)
        XCTAssertFalse(forge.prefix!.contains("secret"), "only the 4-character prefix may appear")
        XCTAssertEqual(forge.prefix, "ghp_")
        XCTAssertTrue(forge.configured)
        XCTAssertEqual(forge.scope, "acme/widgets")
        XCTAssertNil(forge.instance, "GitHub has no instance field")
        XCTAssertTrue(forge.detail.contains("acme/widgets"))
    }

    func testGitHubUnconfiguredScopeIsNullAndSaysSo() {
        let forge = report(stored: [.github: "ghp_x"], config: Self.config(repo: "")).forges[0]
        XCTAssertTrue(forge.stored)
        XCTAssertFalse(forge.configured)
        XCTAssertNil(forge.scope)
        XCTAssertTrue(forge.detail.contains("add a github account to config.yaml"))
    }

    func testGitHubMissingTokenPointsAtAuthSet() {
        let forge = report(config: Self.config()).forges[0]
        XCTAssertFalse(forge.stored)
        XCTAssertNil(forge.prefix)
        XCTAssertTrue(forge.detail.contains("kinhin auth set"))
    }

    // MARK: - Gitea entries

    func testGiteaConfiguredCarriesScopeAndInstance() {
        let forge = report(stored: [.gitea: "gt_live_9"], config: Self.config(gitea: true)).forges[1]
        XCTAssertTrue(forge.stored)
        XCTAssertTrue(forge.configured)
        XCTAssertEqual(forge.scope, "acme")
        XCTAssertEqual(forge.instance, "https://gitea.example.com")
        XCTAssertTrue(forge.detail.contains("scope: acme"))
        XCTAssertTrue(forge.detail.contains("https://gitea.example.com"))
    }

    /// A token stored before the config declares gitea: stays visible but is
    /// marked not-in-use — scripts must be able to distinguish that state.
    func testGiteaStoredWithoutConfigIsStoredButUnconfigured() {
        let forge = reportWithDefaultConfig(stored: [.gitea: "gt_x"]).forges[1]
        XCTAssertTrue(forge.stored)
        XCTAssertFalse(forge.configured, "no gitea account → not in use")
        XCTAssertNil(forge.scope)
        XCTAssertNil(forge.instance)
        XCTAssertTrue(forge.detail.contains("add a gitea account to config.yaml"))
    }

    func testGiteaUnconfiguredWithoutTokenStaysACleanFalse() {
        let forge = reportWithDefaultConfig().forges[1]
        XCTAssertFalse(forge.stored)
        XCTAssertFalse(forge.configured)
    }

    // MARK: - allGood (drives the CLI exit code)

    func testAllGoodOnlyWhenEveryRequiredTokenIsStored() {
        XCTAssertTrue(
            report(stored: [.github: "ghp_x"], config: Self.config()).allGood,
            "GitHub stored + scoped, Gitea unconfigured → all good")
        XCTAssertFalse(
            report(config: Self.config()).allGood,
            "no GitHub token → not good")
        XCTAssertFalse(
            report(stored: [.github: "ghp_x"], config: Self.config(gitea: true)).allGood,
            "gitea configured but no token → not good")
        XCTAssertTrue(
            report(stored: [.github: "ghp_x", .gitea: "gt_x"], config: Self.config(gitea: true)).allGood,
            "every required token stored → all good")
        XCTAssertFalse(
            report(stored: [.gitea: "gt_x"], config: Self.config()).allGood,
            "Gitea token alone never satisfies the report")
        XCTAssertFalse(
            report(stored: [.github: "ghp_x"], config: Self.config(repo: "")).allGood,
            "a stored token without a scope is not usable")
    }

    func testNilConfigStillProducesAGithubEntry() {
        let report = report(config: nil)
        XCTAssertEqual(report.forges.count, 3, "all forges are always reported")
        XCTAssertFalse(report.forges[0].configured)
        XCTAssertFalse(report.allGood)
    }

    // MARK: - CLI flow (`auth status --json` through AuthEnvironment)

    private struct ReportExit: Error { let code: Int }

    /// Recording environment: exit codes are catchable, config comes from a
    /// fixture, `load` stands in for the Keychain — same pattern as
    /// AuthCommandTests, so no real keychain or file is touched.
    private func makeEnvironment(
        stored: [ForgeID: String] = [:],
        config: KinhinConfig?,
        onExit: @escaping @Sendable (Int) throws -> Never = { _ in throw ReportExit(code: -1) }
    ) -> AuthEnvironment {
        AuthEnvironment(
            save: { _, _ in },
            load: { stored[$0] },
            delete: { _ in },
            readToken: { nil },
            checkGitHub: { _ in },
            checkGitea: { _ in },
            loadConfig: { config ?? KinhinConfig.default },
            notifyDaemon: { _, _ in },
            fail: { _ in throw ReportExit(code: 1) },
            exit: { code in try onExit(code) },
            loadAccount: { forge, _ in stored[forge] },
            jsonConfig: .some(config)
        )
    }

    func testJSONStatusEmitsParseableDocument() async throws {
        let cfg = Self.config()
        let env = makeEnvironment(stored: [.github: "ghp_live"], config: cfg)

        // The command's emitter returns exactly the document it printed —
        // decode the returned data to prove the emitted JSON is the contract.
        let (_, data) = try AuthCommand.emitStatusJSON(environment: env)
        let decoded = try JSONDecoder().decode(AuthStatusReport.self, from: data)
        XCTAssertTrue(decoded.allGood)
        XCTAssertEqual(decoded.forges.map(\.id), ["github", "gitea", "forgejo"])
        XCTAssertTrue(decoded.forges[0].stored)
        XCTAssertFalse(decoded.forges[0].prefix!.contains("live"), "the emitted prefix is masked, never the secret")
    }

    func testJSONStatusRunExits1WhenARequiredTokenIsMissing() async {
        let cfg = Self.config()
        let env = makeEnvironment(config: cfg) { code in
            XCTAssertEqual(code, 1, "allGood == false must exit 1 so `&&`-chained setup scripts stop")
            throw ReportExit(code: code)
        }

        do {
            try await AuthCommand.run(["auth", "status", "--json"], environment: env)
            XCTFail("expected exit(1)")
        } catch let error as ReportExit {
            XCTAssertEqual(error.code, 1)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testJSONStatusNeverProbesTheForgeAPIs() async throws {
        // The check hooks would record if touched; --json must stay static.
        let cfg = Self.config()
        let frozen = cfg
        let probed = Mutex(false)
        let env = AuthEnvironment(
            save: { _, _ in },
            load: { [.github: "ghp_x"][$0] },
            delete: { _ in },
            readToken: { nil },
            checkGitHub: { _ in probed.withLock { $0 = true } },
            checkGitea: { _ in probed.withLock { $0 = true } },
            loadConfig: { frozen },
            notifyDaemon: { _, _ in },
            fail: { _ in throw ReportExit(code: 1) },
            exit: { _ in throw ReportExit(code: 1) },
            loadAccount: { forge, _ in [.github: "ghp_x"][forge] },
            jsonConfig: .some(frozen)
        )

        try await AuthCommand.run(["auth", "status", "--json"], environment: env)
        XCTAssertFalse(probed.withLock { $0 }, "the JSON snapshot is static — no network probes")
    }
}
