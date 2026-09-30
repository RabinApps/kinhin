import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin

/// The `kinhin auth status --json` CLI flow: the emitted document, the
/// allGood → exit-1 rule, and the guarantee that `--json` never probes
/// the forge APIs. Reporter behavior itself is covered in KinhinKitTests.
final class AuthStatusReportTests: XCTestCase {
    // MARK: - CLI flow (`auth status --json` through AuthEnvironment)

    private struct ReportExit: Error { let code: Int }

    /// The same shape as the reporter tests' fixture: a working GitHub
    /// account, optionally plus a Gitea one.
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
