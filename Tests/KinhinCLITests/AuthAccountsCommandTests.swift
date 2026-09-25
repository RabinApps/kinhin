import XCTest

@testable import KinhinKit
@testable import kinhin

/// `auth add|list|remove` and `--account` flows, driven through an injected
/// `AuthEnvironment` (no Keychain, network, or daemon).
final class AuthAccountsCommandTests: XCTestCase {
    private struct AuthFailure: Error { let message: String }
    private struct AuthExit: Error { let code: Int }

    private final class Recorder {
        var savedAccounts: [(token: String, forge: ForgeID, name: String)] = []
        var deletedAccounts: [(ForgeID, String)] = []
        var notified: [(account: String, token: String)] = []
        var checkedGitHub: [GitHubCredentials] = []
        var checkedGitea: [GiteaCredentials] = []
    }

    private var configURL: URL!

    override func setUp() {
        super.setUp()
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-auth-\(UUID().uuidString).yaml")
        try? "repo: acme/widgets\nlabels: [a]\n".write(to: configURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: configURL)
        super.tearDown()
    }

    private func environment(
        _ recorder: Recorder, stored: [String: String] = [:], readToken: String? = nil
    ) -> AuthEnvironment {
        let config = (try? ConfigLoader.load(from: configURL)) ?? KinhinConfig.default
        var env = AuthEnvironment(
            save: { _, _ in XCTFail("legacy save must not be used for a named account") },
            load: { _ in nil },
            delete: { _ in XCTFail("legacy delete must not be used for a named account") },
            readToken: { readToken },
            checkGitHub: { recorder.checkedGitHub.append($0) },
            checkGitea: { recorder.checkedGitea.append($0) },
            loadConfig: { config },
            notifyDaemon: { _, _ in XCTFail("legacy notify must not be used for a named account") },
            fail: { throw AuthFailure(message: $0) },
            exit: { throw AuthExit(code: $0) }
        )
        env.saveAccount = { token, forge, name in recorder.savedAccounts.append((token, forge, name)) }
        env.loadAccount = { _, name in stored[name] }
        env.deleteAccount = { recorder.deletedAccounts.append(($0, $1)) }
        env.notifyDaemonAccount = { recorder.notified.append(($0, $1)) }
        env.configURL = configURL
        env.jsonConfig = .some(config)
        return env
    }

    private func addWork(_ recorder: Recorder) async throws {
        try await AuthCommand.run(
            ["auth", "add", "work", "--github", "--scope", "bigco"], environment: environment(recorder))
    }

    func testAddWritesConfigAndAcceptsAToken() async throws {
        let recorder = Recorder()
        try await AuthCommand.run(
            ["auth", "add", "work", "--github", "--scope", "bigco", "--token", "ghp_x"],
            environment: environment(recorder))
        XCTAssertEqual(try ConfigLoader.load(from: configURL).accounts.map(\.name), ["work"])
        XCTAssertEqual(recorder.savedAccounts.count, 1)
        XCTAssertEqual(recorder.savedAccounts.first?.name, "work")
        XCTAssertEqual(recorder.notified.first?.account, "work")
    }

    func testAddRequiresExactlyOneForgeAndAScope() async throws {
        let recorder = Recorder()
        for args in [
            ["auth", "add", "x", "--scope", "s"], ["auth", "add", "x", "--github", "--gitea", "--scope", "s"],
            ["auth", "add", "x", "--github"], ["auth", "add"],
        ] {
            do {
                try await AuthCommand.run(args, environment: environment(recorder))
                XCTFail("expected failure for \(args)")
            } catch is AuthFailure {}
        }
    }

    func testAddRejectsAnInvalidAccountWithoutTouchingTheFile() async throws {
        let before = try String(contentsOf: configURL, encoding: .utf8)
        do {
            try await AuthCommand.run(
                ["auth", "add", "home", "--gitea", "--scope", "me"], environment: environment(Recorder()))
            XCTFail("a gitea account needs --instance")
        } catch is AuthFailure {}
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), before)
    }

    func testSetForANamedAccountUsesItsOwnKeychainItem() async throws {
        let recorder = Recorder()
        try await addWork(recorder)
        try await AuthCommand.run(
            ["auth", "set", "--account", "work", "--token", "ghp_new"], environment: environment(recorder))
        XCTAssertEqual(recorder.savedAccounts.first?.token, "ghp_new")
        XCTAssertEqual(recorder.savedAccounts.first?.forge, .github)
        XCTAssertEqual(recorder.savedAccounts.first?.name, "work")
        XCTAssertEqual(recorder.notified.first?.account, "work")
    }

    func testSetForAnUnknownAccountPointsAtAdd() async throws {
        do {
            try await AuthCommand.run(
                ["auth", "set", "--account", "ghost", "--token", "x"], environment: environment(Recorder()))
            XCTFail("expected failure")
        } catch let error as AuthFailure {
            XCTAssertTrue(error.message.contains("kinhin auth add ghost"), error.message)
        }
    }

    func testStatusChecksTheAccountsScope() async throws {
        let recorder = Recorder()
        try await addWork(recorder)
        try await AuthCommand.run(
            ["auth", "status", "--account", "work"], environment: environment(recorder, stored: ["work": "ghp_abcd"]))
        XCTAssertEqual(recorder.checkedGitHub.first?.token, "ghp_abcd")
        XCTAssertEqual(recorder.checkedGitHub.first?.scope, "bigco")
    }

    func testStatusWithoutATokenExitsNonZero() async throws {
        let recorder = Recorder()
        try await addWork(recorder)
        do {
            try await AuthCommand.run(["auth", "status", "--account", "work"], environment: environment(recorder))
            XCTFail("expected exit")
        } catch let exit as AuthExit {
            XCTAssertEqual(exit.code, 1)
        }
    }

    func testClearDeletesOnlyThatAccountsToken() async throws {
        let recorder = Recorder()
        try await addWork(recorder)
        try await AuthCommand.run(["auth", "clear", "--account", "work"], environment: environment(recorder))
        XCTAssertEqual(recorder.deletedAccounts.count, 1)
        XCTAssertEqual(recorder.deletedAccounts.first?.1, "work")
    }

    func testRemoveDropsConfigEntryAndToken() async throws {
        let recorder = Recorder()
        try await addWork(recorder)
        try await AuthCommand.run(["auth", "remove", "work"], environment: environment(recorder))
        XCTAssertTrue(try ConfigLoader.load(from: configURL).accounts.isEmpty)
        XCTAssertEqual(recorder.deletedAccounts.first?.1, "work")
    }

    func testRemoveRefusesLegacyAndUnknownAccounts() async throws {
        for name in ["github", "ghost"] {
            do {
                try await AuthCommand.run(["auth", "remove", name], environment: environment(Recorder()))
                XCTFail("expected failure for \(name)")
            } catch is AuthFailure {}
        }
    }

    func testStatusJSONListsAccounts() async throws {
        let recorder = Recorder()
        try await addWork(recorder)
        let (report, _) = try AuthCommand.emitStatusJSON(
            environment: environment(recorder, stored: ["work": "ghp_abcd"]))
        XCTAssertEqual(report.accounts.map(\.name), ["work"])
        XCTAssertEqual(report.accounts.first?.stored, true)
        XCTAssertEqual(report.accounts.first?.prefix, "ghp_")
    }
}
