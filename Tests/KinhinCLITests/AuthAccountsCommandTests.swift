import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin

/// `auth add|list|remove` and `--account` flows, driven through an injected
/// `AuthEnvironment` (no Keychain, network, or daemon).
final class AuthAccountsCommandTests: XCTestCase {
    var configURL: URL!
    /// Scratch config parsed once per environment build (reset by `environment`).
    var frozen: KinhinConfig?

    override func setUp() {
        super.setUp()
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-auth-\(UUID().uuidString).yaml")
        try? "labels: [a]\n".write(to: configURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: configURL)
        super.tearDown()
    }

    /// Thin wrapper so the call sites keep their shape; the body lives in
    /// the shared `AuthTestSupport` harness.
    private func environment(
        _ recorder: AuthRecorder, stored: [String: String] = [:], readToken: String? = nil
    ) -> AuthEnvironment {
        frozen = nil  // re-read the scratch config each time
        return makeAccountsEnvironment(recorder, stored: stored, readToken: readToken)
    }

    private func addWork(_ recorder: AuthRecorder) async throws {
        try await AuthCommand.run(
            ["auth", "add", "work", "--github", "--scope", "bigco"], environment: environment(recorder))
    }

    func testAddWritesConfigAndAcceptsAToken() async throws {
        let recorder = AuthRecorder()
        try await AuthCommand.run(
            ["auth", "add", "work", "--github", "--scope", "bigco", "--token", "ghp_x"],
            environment: environment(recorder))
        XCTAssertEqual(try ConfigLoader.load(from: configURL).accounts.map(\.name), ["work"])
        XCTAssertEqual(recorder.savedAccounts.count, 1)
        XCTAssertEqual(recorder.savedAccounts.first?.name, "work")
        XCTAssertEqual(recorder.notifiedAccounts.first?.account, "work")
    }

    func testAddRequiresExactlyOneForgeAndAScope() async throws {
        let recorder = AuthRecorder()
        for args in [
            ["auth", "add", "x", "--scope", "s"], ["auth", "add", "x", "--github", "--gitea", "--scope", "s"],
            ["auth", "add", "x", "--github"], ["auth", "add"],
        ] {
            do {
                try await AuthCommand.run(args, environment: environment(recorder))
                XCTFail("expected failure for \(args)")
            } catch is AuthTestSupport.AuthFailure {}
        }
    }

    func testAddRejectsAnInvalidAccountWithoutTouchingTheFile() async throws {
        let before = try String(contentsOf: configURL, encoding: .utf8)
        do {
            try await AuthCommand.run(
                ["auth", "add", "home", "--gitea", "--scope", "me"], environment: environment(AuthRecorder()))
            XCTFail("a gitea account needs --instance")
        } catch is AuthTestSupport.AuthFailure {}
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), before)
    }

    func testSetForANamedAccountUsesItsOwnKeychainItem() async throws {
        let recorder = AuthRecorder()
        try await addWork(recorder)
        try await AuthCommand.run(
            ["auth", "set", "--account", "work", "--token", "ghp_new"], environment: environment(recorder))
        XCTAssertEqual(recorder.savedAccounts.first?.token, "ghp_new")
        XCTAssertEqual(recorder.savedAccounts.first?.forge, .github)
        XCTAssertEqual(recorder.savedAccounts.first?.name, "work")
        XCTAssertEqual(recorder.notifiedAccounts.first?.account, "work")
    }

    func testSetForAnUnknownAccountPointsAtAdd() async throws {
        do {
            try await AuthCommand.run(
                ["auth", "set", "--account", "ghost", "--token", "x"], environment: environment(AuthRecorder()))
            XCTFail("expected failure")
        } catch let error as AuthTestSupport.AuthFailure {
            XCTAssertTrue(error.message.contains("kinhin auth add ghost"), error.message)
        }
    }

    func testStatusChecksTheAccountsScope() async throws {
        let recorder = AuthRecorder()
        try await addWork(recorder)
        try await AuthCommand.run(
            ["auth", "status", "--account", "work"], environment: environment(recorder, stored: ["work": "ghp_abcd"]))
        XCTAssertEqual(recorder.checkedGitHub.first?.token, "ghp_abcd")
        XCTAssertEqual(recorder.checkedGitHub.first?.scope, "bigco")
    }

    func testStatusWithoutATokenExitsNonZero() async throws {
        let recorder = AuthRecorder()
        try await addWork(recorder)
        do {
            try await AuthCommand.run(["auth", "status", "--account", "work"], environment: environment(recorder))
            XCTFail("expected exit")
        } catch let exit as AuthTestSupport.AuthExit {
            XCTAssertEqual(exit.code, 1)
        }
    }

    func testClearDeletesOnlyThatAccountsToken() async throws {
        let recorder = AuthRecorder()
        try await addWork(recorder)
        try await AuthCommand.run(["auth", "clear", "--account", "work"], environment: environment(recorder))
        XCTAssertEqual(recorder.deletedAccounts.count, 1)
        XCTAssertEqual(recorder.deletedAccounts.first?.1, "work")
    }

    func testRemoveDropsConfigEntryAndToken() async throws {
        let recorder = AuthRecorder()
        try await addWork(recorder)
        try await AuthCommand.run(["auth", "remove", "work"], environment: environment(recorder))
        XCTAssertTrue(try ConfigLoader.load(from: configURL).accounts.isEmpty)
        XCTAssertEqual(recorder.deletedAccounts.first?.1, "work")
    }

    func testRemoveRefusesLegacyAndUnknownAccounts() async throws {
        for name in ["github", "ghost"] {
            do {
                try await AuthCommand.run(["auth", "remove", name], environment: environment(AuthRecorder()))
                XCTFail("expected failure for \(name)")
            } catch is AuthTestSupport.AuthFailure {}
        }
    }

    func testStatusJSONListsAccounts() async throws {
        let recorder = AuthRecorder()
        try await addWork(recorder)
        let (report, _) = try AuthCommand.emitStatusJSON(
            environment: environment(recorder, stored: ["work": "ghp_abcd"]))
        XCTAssertEqual(report.accounts.map(\.name), ["work"])
        XCTAssertEqual(report.accounts.first?.stored, true)
        XCTAssertEqual(report.accounts.first?.prefix, "ghp_")
    }

    /// `--account NAME` narrows the JSON document and the exit verdict to that account.
    func testStatusJSONNarrowsToTheNamedAccount() async throws {
        let recorder = AuthRecorder()
        try await addWork(recorder)
        try await AuthCommand.run(
            ["auth", "add", "other", "--github", "--scope", "elsewhere"], environment: environment(recorder))
        let env = environment(recorder, stored: ["work": "ghp_abcd"])
        let (all, _) = try AuthCommand.emitStatusJSON(environment: env, quiet: true)
        XCTAssertEqual(all.accounts.map(\.name).sorted(), ["other", "work"])
        XCTAssertFalse(all.allGood, "the account without a token spoils the full report")

        let (work, _) = try AuthCommand.emitStatusJSON(environment: env, quiet: true, account: "work")
        XCTAssertEqual(work.accounts.map(\.name), ["work"])
        XCTAssertTrue(work.forges.isEmpty)
        XCTAssertTrue(work.allGood)

        let (other, _) = try AuthCommand.emitStatusJSON(environment: env, quiet: true, account: "other")
        XCTAssertFalse(other.allGood)
    }

    /// A stored token with an empty scope cannot route a job: the narrowed verdict matches the full report's.
    func testNarrowedReportRequiresAScopeLikeTheFullReport() {
        let row = AuthStatusReport.Account(
            name: "work", forge: "github", stored: true, prefix: "ghp_", scope: "", instance: nil, detail: "")
        let report = AuthStatusReport(forges: [], allGood: false, accounts: [row])
        XCTAssertFalse(report.narrowed(toAccount: "work").allGood)
    }

    func testListedAccountsReportTokenStateWithoutTheToken() async throws {
        let recorder = AuthRecorder()
        try await addWork(recorder)
        let rows = AuthCommand.listedAccounts(environment: environment(recorder, stored: ["work": "ghp_secret"]))
        XCTAssertEqual(rows.map(\.name), ["work"])
        XCTAssertEqual(rows.first?.token, "stored")
        XCTAssertEqual(rows.first?.forge, "github")
        XCTAssertEqual(rows.first?.scope, "bigco")
        let encoded = try String(decoding: JSONEncoder().encode(rows), as: UTF8.self)
        XCTAssertFalse(encoded.contains("ghp_secret"), "the token never appears in the listing")
        XCTAssertEqual(
            AuthCommand.listedAccounts(environment: environment(recorder)).first?.token, "none")
    }

    // MARK: - GitLab

    func testGitLabAccountRoundTrip() async throws {
        let recorder = AuthRecorder()
        try await AuthCommand.run(
            ["auth", "add", "gitlab", "--gitlab", "--scope", "acme/platform/api"], environment: environment(recorder))
        let account = try XCTUnwrap(try ConfigLoader.load(from: configURL).accounts.first)
        XCTAssertEqual(account.forge, .gitlab)
        XCTAssertEqual(account.scope, "acme/platform/api")
        XCTAssertNil(account.instance, "gitlab.com by default")

        // --gitlab targets the GitLab account through its own Keychain item and RPC.
        try await AuthCommand.run(
            ["auth", "set", "--gitlab", "--token", "glpat-x"], environment: environment(recorder))
        XCTAssertEqual(recorder.savedAccounts.last?.forge, .gitlab)
        XCTAssertEqual(recorder.savedAccounts.last?.name, "gitlab")
        XCTAssertEqual(recorder.notifiedAccounts.last?.account, "gitlab")

        try await AuthCommand.run(
            ["auth", "status", "--gitlab"], environment: environment(recorder, stored: ["gitlab": "glpat-x"]))
        XCTAssertEqual(recorder.checkedGitLab.first?.scope, "acme/platform/api")
        XCTAssertEqual(recorder.checkedGitLab.first?.instance, GitLabCredentials.defaultInstance)
        XCTAssertTrue(recorder.checkedGitHub.isEmpty, "a GitLab account is never checked against GitHub")
    }

    func testGitLabFlagWithoutAnAccountPointsAtAdd() async throws {
        do {
            try await AuthCommand.run(
                ["auth", "set", "--gitlab", "--token", "x"], environment: environment(AuthRecorder()))
            XCTFail("expected failure")
        } catch let error as AuthTestSupport.AuthFailure {
            XCTAssertTrue(error.message.contains("auth add NAME --gitlab"), error.message)
        }
    }

    func testBuildkiteAccountRoundTrip() async throws {
        let recorder = AuthRecorder()
        try await AuthCommand.run(
            ["auth", "add", "ci", "--buildkite", "--scope", "acme/Mac Fleet"], environment: environment(recorder))
        let account = try XCTUnwrap(try ConfigLoader.load(from: configURL).accounts.first)
        XCTAssertEqual(account.forge, .buildkite)
        XCTAssertEqual(account.scope, "acme/Mac Fleet")

        // --buildkite targets the first Buildkite account's own Keychain item.
        try await AuthCommand.run(
            ["auth", "set", "--buildkite", "--token", "bkua_x"], environment: environment(recorder))
        XCTAssertEqual(recorder.savedAccounts.last?.forge, .buildkite)
        XCTAssertEqual(recorder.savedAccounts.last?.name, "ci")

        try await AuthCommand.run(
            ["auth", "status", "--buildkite"], environment: environment(recorder, stored: ["ci": "bkua_x"]))
        XCTAssertEqual(recorder.checkedBuildkite.first?.scope, "acme/Mac Fleet")
        XCTAssertTrue(recorder.checkedGitHub.isEmpty, "a Buildkite account is never checked against GitHub")
    }

    func testAzureDevOpsAccountRoundTrip() async throws {
        let recorder = AuthRecorder()
        try await AuthCommand.run(
            [
                "auth", "add", "ado", "--azuredevops", "--scope", "Mac Fleet", "--instance",
                "https://dev.azure.com/acme",
            ],
            environment: environment(recorder))
        let account = try XCTUnwrap(try ConfigLoader.load(from: configURL).accounts.first)
        XCTAssertEqual(account.forge, .azuredevops)
        XCTAssertEqual(account.instance, "https://dev.azure.com/acme")

        try await AuthCommand.run(
            ["auth", "set", "--azuredevops", "--token", "pat"], environment: environment(recorder))
        XCTAssertEqual(recorder.savedAccounts.last?.forge, .azuredevops)
        XCTAssertEqual(recorder.savedAccounts.last?.name, "ado")

        try await AuthCommand.run(
            ["auth", "status", "--azuredevops"], environment: environment(recorder, stored: ["ado": "pat"]))
        XCTAssertEqual(recorder.checkedAzureDevOps.first?.scope, "Mac Fleet")
        XCTAssertEqual(recorder.checkedAzureDevOps.first?.instance, "https://dev.azure.com/acme")
    }
}
