import XCTest

@testable import KinhinKit

/// `http://` instances need `allow_insecure_http: true` on the account.
final class InsecureHTTPAccountConfigTests: XCTestCase {
    private func parse(_ account: String) throws -> KinhinConfig {
        try ConfigLoader.parse(
            """
            labels: [macos]
            accounts:
            \(account)
            """)
    }

    private func message(_ account: String) -> String {
        do {
            _ = try parse(account)
            return "parsed"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func testPlainHTTPWithoutTheFlagIsRejectedWithAnExplanation() {
        for (forge, scope) in [("gitea", "me/repo"), ("forgejo", "me/repo"), ("gitlab", "grp/proj")] {
            let text = message(
                """
                  - name: lab
                    forge: \(forge)
                    scope: \(scope)
                    instance: http://git.lan:3000
                """)
            XCTAssertTrue(text.contains("plain http"), "\(forge): \(text)")
            XCTAssertTrue(text.contains("allow_insecure_http"), "\(forge): \(text)")
        }
        let azure = message(
            """
              - name: ado
                forge: azuredevops
                scope: Mac Fleet
                instance: http://tfs.lan/tfs/DefaultCollection
            """)
        XCTAssertTrue(azure.contains("allow_insecure_http"), azure)
    }

    func testTheFlagLetsAnHTTPInstanceThrough() throws {
        let cfg = try parse(
            """
              - name: lab
                forge: gitea
                scope: me/repo
                instance: http://git.lan:3000
                allow_insecure_http: true
            """)
        let account = try XCTUnwrap(cfg.accounts.first)
        XCTAssertEqual(account.allowInsecureHTTP, true)
        XCTAssertEqual(account.instance, "http://git.lan:3000")
    }

    func testLoopbackNeedsNoFlag() throws {
        let cfg = try parse(
            """
              - name: dev
                forge: gitea
                scope: me/repo
                instance: http://localhost:3000
            """)
        XCTAssertNil(try XCTUnwrap(cfg.accounts.first).allowInsecureHTTP)
    }

    func testHTTPSNeverNeedsTheFlag() throws {
        XCTAssertNoThrow(
            try parse(
                """
                  - name: ok
                    forge: gitlab
                    scope: grp/proj
                    instance: https://gitlab.example.com
                """))
    }

    func testHostedForgesRejectTheFlag() {
        for (forge, scope) in [("github", "acme"), ("buildkite", "org/cluster"), ("bitbucket", "acme")] {
            let text = message(
                """
                  - name: hosted
                    forge: \(forge)
                    scope: \(scope)
                    allow_insecure_http: true
                """)
            XCTAssertTrue(text.contains("self-hosted"), "\(forge): \(text)")
        }
    }

    func testEditorKeepsTheFlagWhenRewritingAccounts() throws {
        let account = AccountConfig(
            name: "lab", forge: .gitea, scope: "me/repo", instance: "http://git.lan:3000", allowInsecureHTTP: true)
        let text = AccountsConfigEditor.sectionText([account])
        XCTAssertTrue(text.contains("allow_insecure_http: true"), text)
        let reparsed = try parse(text.split(separator: "\n").dropFirst().joined(separator: "\n"))
        XCTAssertEqual(reparsed.accounts.first?.allowInsecureHTTP, true)

        let secure = AccountConfig(name: "ok", forge: .gitea, scope: "me/repo", instance: "https://g.example.com")
        XCTAssertFalse(AccountsConfigEditor.sectionText([secure]).contains("allow_insecure_http"))
    }
}
