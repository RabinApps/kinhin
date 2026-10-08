import Synchronization
import XCTest

@testable import KinhinKit

/// Two accounts of one forge must each be checked and reported with their own
/// token: tokens are keyed by account name, never by forge alone.
final class MultiAccountTokenTests: XCTestCase {
    private let config = try! ConfigLoader.parse(
        """
        labels: [a]
        accounts:
          - {name: gl-a, forge: gitlab, scope: team-a/api, instance: "https://gitlab.a.example"}
          - {name: gl-b, forge: gitlab, scope: team-b/web, instance: "https://gitlab.b.example"}
          - {name: gitea, forge: gitea, scope: org/main, instance: "https://git.example"}
          - {name: side, forge: gitea, scope: org/side, instance: "https://git.example"}

        """)

    private let tokens: [String: String] = [
        "gitlab/gl-a": "glpat-AAAA", "gitlab/gl-b": "glpat-BBBB",
        "gitea/gitea": "gitea-MAIN", "gitea/side": "gitea-SIDE",
    ]

    // MARK: - TokenHealthCheck.resolve

    private func resolve(_ forge: ForgeID, _ name: String?)
        -> TokenHealthCheck.Resolution
    {
        TokenHealthCheck.resolve(forge: forge, account: name, config: config) { forge, name in
            return tokens["\(forge.rawValue)/\(name)"]
        }
    }

    func testEachGitLabAccountIsCheckedWithItsOwnTokenAndScope() throws {
        guard case .ready(let a, let tokenA) = resolve(.gitlab, "gl-a") else { return XCTFail("gl-a not ready") }
        guard case .ready(let b, let tokenB) = resolve(.gitlab, "gl-b") else { return XCTFail("gl-b not ready") }
        XCTAssertEqual([a.name, a.scope, tokenA], ["gl-a", "team-a/api", "glpat-AAAA"])
        XCTAssertEqual([b.name, b.scope, tokenB], ["gl-b", "team-b/web", "glpat-BBBB"])
        XCTAssertEqual(b.instance, "https://gitlab.b.example")
    }

    func testTheTokenIsReadByAccountNameNotByForge() {
        var calls: [String] = []
        _ = TokenHealthCheck.resolve(forge: .gitlab, account: "gl-b", config: config) { forge, name in
            calls.append("\(forge.rawValue)/\(name)")
            return "t"
        }
        XCTAssertEqual(calls, ["gitlab/gl-b"])
    }

    func testWithoutANameTheConventionalAccountWins() {
        guard case .ready(let account, let token) = resolve(.gitea, nil) else { return XCTFail("not ready") }
        XCTAssertEqual(account.name, "gitea", "the account named like the forge, not the first Gitea entry")
        XCTAssertEqual(token, "gitea-MAIN")
        guard case .ready(let first, let firstToken) = resolve(.gitlab, nil) else { return XCTFail("not ready") }
        XCTAssertEqual(first.name, "gl-a", "no conventional account: the forge's first")
        XCTAssertEqual(firstToken, "glpat-AAAA")
    }

    func testAMissingTokenForOneAccountDoesNotBorrowTheOthers() {
        var partial = tokens
        partial["gitlab/gl-b"] = nil
        let result = TokenHealthCheck.resolve(forge: .gitlab, account: "gl-b", config: config) { forge, name in
            partial["\(forge.rawValue)/\(name)"]
        }
        guard case .notCheckable(let report) = result else { return XCTFail("gl-a's token must not stand in") }
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.message.contains("kinhin auth set --account gl-b"), report.message)
    }

    func testAnUnknownAccountNameIsNotCheckable() {
        guard case .notCheckable(let report) = resolve(.gitlab, "gl-z") else { return XCTFail("expected a refusal") }
        XCTAssertTrue(report.message.contains("'gl-z'"), report.message)
    }

    func testAForgeMismatchIsNotCheckable() {
        guard case .notCheckable = resolve(.github, "gl-a") else { return XCTFail("gl-a is not a GitHub account") }
    }

    // MARK: - AuthStatusReporter

    private func report(
        load: @escaping (ForgeID) throws -> String? = { _ in nil }
    ) -> AuthStatusReport {
        AuthStatusReporter.report(
            config: config, load: load, loadAccount: { [tokens] forge, name in tokens["\(forge.rawValue)/\(name)"] })
    }

    func testEachGitLabAccountRowCarriesItsOwnToken() throws {
        let report = report(load: { _ in "forge-keyed-token" })
        let a = try XCTUnwrap(report.accounts.first { $0.name == "gl-a" })
        let b = try XCTUnwrap(report.accounts.first { $0.name == "gl-b" })
        XCTAssertEqual(a.prefix, "glpa")
        XCTAssertEqual(b.prefix, "glpa")
        XCTAssertTrue(a.detail.contains("team-a/api"), a.detail)
        XCTAssertTrue(b.detail.contains("team-b/web"), b.detail)
        XCTAssertTrue(report.allGood)
    }

    func testTheLegacyForgeRowIsAViewOfItsAccountsToken() throws {
        // The forge-keyed Keychain item holds something else entirely; the
        // row must show the token of the account it describes.
        let report = report(load: { _ in "WRONG-forge-keyed" })
        let gitea = try XCTUnwrap(report.forges.first { $0.id == "gitea" })
        XCTAssertEqual(gitea.prefix, "gite")
        XCTAssertTrue(gitea.stored)
        XCTAssertEqual(gitea.scope, "org/main", "the conventional 'gitea' account, not 'side'")
        XCTAssertFalse(gitea.detail.contains("WRONG"))
    }

    func testTheLegacyForgeRowFollowsTheFirstAccountWhenNoneIsConventional() throws {
        let cfg = try ConfigLoader.parse(
            """
            labels: [a]
            accounts:
              - {name: side, forge: gitea, scope: org/side, instance: "https://git.example"}

            """)
        let report = AuthStatusReporter.report(
            config: cfg, load: { _ in "gitea-FORGE-KEYED" },
            loadAccount: { _, name in name == "side" ? "gitea-SIDE" : nil })
        let row = try XCTUnwrap(report.forges.first { $0.id == "gitea" })
        XCTAssertEqual(row.scope, "org/side")
        XCTAssertEqual(row.prefix, "gite")
        XCTAssertTrue(row.detail.contains("(gite…)"), row.detail)
    }

    func testAForgeWithoutAnAccountStillReportsAForgeKeyedToken() throws {
        let report = AuthStatusReporter.report(
            config: nil, load: { $0 == .github ? "ghp_orphan" : nil }, loadAccount: { _, _ in nil })
        let github = try XCTUnwrap(report.forges.first { $0.id == "github" })
        XCTAssertTrue(github.stored)
        XCTAssertFalse(github.configured)
        XCTAssertTrue(github.detail.contains("add a github account"), github.detail)
    }

    // MARK: - AuthFix

    func testAuthFixNamesTheAccountAndNeverSuggestsGiteaFlagForForgejo() {
        XCTAssertEqual(AuthFix.command(forge: .gitlab, account: "gl-b"), "kinhin auth set --account gl-b")
        XCTAssertEqual(AuthFix.command(forge: .forgejo, account: "codeberg"), "kinhin auth set --account codeberg")
        XCTAssertEqual(AuthFix.command(forge: .github, account: nil), "kinhin auth set")
        for forge in ForgeID.allCases where forge != .github {
            let command = AuthFix.command(forge: forge, account: nil)
            XCTAssertEqual(command, "kinhin auth set --account NAME", "\(forge)")
            XCTAssertFalse(command.contains("--gitea"))
        }
    }
}
