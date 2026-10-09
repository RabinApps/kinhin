import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// A Keychain that can't be read (locked, prompt denied) is not the same as
/// "no token saved": every surface must say what happened instead of sending
/// the user to re-enter a token they already stored.
final class TokenReadFailureTests: XCTestCase {
    private struct KeychainDown: LocalizedError {
        var errorDescription: String? { "the login keychain is locked" }
    }

    private func githubConfig() -> KinhinConfig { makeTestConfig() }

    private func configWithAccount() throws -> KinhinConfig {
        try ConfigLoader.parse(
            """
            accounts:
              - {name: work, forge: github, scope: bigco}
            labels: [x]

            """)
    }

    // MARK: - Store

    func testUnreadableErrorNamesTheAccountAndTheReason() {
        let error = KeychainTokenStore.TokenError.unreadable(account: "github-pat", reason: "User canceled (-128)")
        XCTAssertEqual(
            error.errorDescription,
            "couldn't read the github-pat token from the Keychain: User canceled (-128)")
    }

    // MARK: - Engine token

    func testEngineTokenPropagatesAKeychainFailure() {
        XCTAssertThrowsError(
            try ConfigLoader.engineToken(for: githubConfig(), loadAccount: { _, _ in throw KeychainDown() })
        ) {
            XCTAssertEqual($0.localizedDescription, "the login keychain is locked")
        }
    }

    func testEngineTokenPropagatesAnAccountFailure() throws {
        let cfg = try configWithAccount()
        XCTAssertThrowsError(
            try ConfigLoader.engineToken(for: cfg, loadAccount: { _, _ in throw KeychainDown() }))
    }

    func testAnyStoredPropagatesAKeychainFailure() {
        XCTAssertThrowsError(
            try AccountTokens.anyStored(for: .github, config: githubConfig(), load: { _, _ in throw KeychainDown() }))
    }

    // MARK: - Reports

    func testAuthReportShowsTheKeychainErrorNotNoToken() throws {
        let cfg = try configWithAccount()
        let report = AuthStatusReporter.report(
            config: cfg, load: { _ in throw KeychainDown() }, loadAccount: { _, _ in throw KeychainDown() })
        let github = try XCTUnwrap(report.forges.first { $0.id == "github" })
        XCTAssertFalse(github.stored)
        XCTAssertTrue(github.detail.contains("Keychain error — the login keychain is locked"), github.detail)
        XCTAssertFalse(github.detail.contains("no token stored"), github.detail)
        let account = try XCTUnwrap(report.accounts.first)
        XCTAssertTrue(account.detail.contains("Keychain error"), account.detail)
        XCTAssertFalse(report.allGood)
    }

    func testAuthReportStillWorksWhenOnlyOneReadFails() throws {
        let cfg = githubConfig()
        // `makeTestConfig()` configures a GitHub account, so the per-forge row
        // reads *that account's* token through `loadAccount`, not the forge-
        // keyed `load` closure. Inject both so the test models one forge down
        // and one up, which is what it is trying to assert.
        let report = AuthStatusReporter.report(
            config: cfg,
            load: { _ in throw KeychainDown() },
            loadAccount: { forge, name in
                if forge == .github && name == cfg.accounts.first?.name { return "ghp_abcd1234" }
                throw KeychainDown()
            })
        let github = try XCTUnwrap(report.forges.first { $0.id == "github" })
        XCTAssertTrue(github.stored)
        let gitea = try XCTUnwrap(report.forges.first { $0.id == "gitea" })
        XCTAssertTrue(gitea.detail.contains("Keychain error"), gitea.detail)
    }

    // MARK: - Checklist

    private func checklist(failures: [String: String]) async -> SetupStatus {
        await SetupStatusComputer(
            host: HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true),
            clt: .ok(version: "16.0"),
            tartHealth: .healthy,
            tartList: [],
            config: .loaded(githubConfig()),
            accountTokensStored: ["github": false],
            tokenReadFailures: failures
        ).compute()
    }

    func testChecklistShowsAKeychainErrorRowWithoutAFixAction() async throws {
        let status = await checklist(failures: ["account:github": "the login keychain is locked"])
        let row = try XCTUnwrap(status.checks.first { $0.id == "account-token-github" })
        XCTAssertFalse(row.ok)
        XCTAssertTrue(row.detail.contains("Keychain error — the login keychain is locked"), row.detail)
        XCTAssertNil(row.action, "re-entering a token can't help when the Keychain won't read")
        XCTAssertFalse(status.ready)
    }

    func testChecklistStillAsksForAMissingTokenWhenThereIsNoFailure() async throws {
        let status = await checklist(failures: [:])
        let row = try XCTUnwrap(status.checks.first { $0.id == "account-token-github" })
        XCTAssertEqual(row.action, "enter_account_token")
        XCTAssertFalse(row.detail.contains("Keychain error"))
    }

    // MARK: - Token health check

    func testTokenHealthCheckReportsAKeychainFailure() async {
        let report = await TokenHealthCheck.check(
            forge: .github, config: githubConfig(), keychainToken: { _, _ in throw KeychainDown() })
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.message.contains("the login keychain is locked"), report.message)
        XCTAssertFalse(report.message.contains("No token stored"), report.message)
    }

    // MARK: - Engine

    private func makeEngine() -> FleetEngine {
        FleetEngine(
            config: githubConfig(), pat: "legacy", tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: testHost)
    }

    func testEngineExplainsAKeychainFailureInLastError() async {
        let engine = makeEngine()
        let token = await engine.storedToken(missing: "no token stored — run: kinhin auth set") {
            throw KeychainDown()
        }
        XCTAssertNil(token)
        let error = await engine.status().lastError
        XCTAssertEqual(error, "the login keychain is locked")
    }

    func testEngineExplainsAMissingTokenAndReturnsAFoundOne() async {
        let engine = makeEngine()
        let missing = await engine.storedToken(missing: "no token stored — run: kinhin auth set") { nil }
        XCTAssertNil(missing)
        let lastError = await engine.status().lastError
        XCTAssertEqual(lastError, "no token stored — run: kinhin auth set")

        let found = await engine.storedToken(missing: "unused") { "tok" }
        XCTAssertEqual(found, "tok")
    }
}
