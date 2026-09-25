import XCTest

@testable import KinhinKit

final class AccountsConfigTests: XCTestCase {
    private let base = """
        repo: acme/widgets
        labels: [self-hosted]

        """

    func testLegacyConfigHasNoExtraAccountsButListsLegacyOnes() throws {
        let cfg = try ConfigLoader.parse(
            base + "gitea:\n  instance: https://g.example.com\n  scope: team\n")
        XCTAssertTrue(cfg.accounts.isEmpty)
        XCTAssertEqual(cfg.allAccounts.map(\.name), ["github", "gitea"])
        XCTAssertEqual(cfg.allAccounts.map(\.forge), [.github, .gitea])
    }

    func testParsesExplicitAccounts() throws {
        let cfg = try ConfigLoader.parse(
            base + """
                accounts:
                  - name: work
                    forge: github
                    scope: bigco
                  - name: home-gitea
                    forge: gitea
                    scope: me/repo
                    instance: https://git.home.lan
                    labels: [macos:host]

                """)
        XCTAssertEqual(cfg.accounts.count, 2)
        XCTAssertEqual(cfg.accounts[0], AccountConfig(name: "work", forge: .github, scope: "bigco"))
        XCTAssertEqual(cfg.accounts[1].instance, "https://git.home.lan")
        XCTAssertEqual(cfg.allAccounts.map(\.name), ["github", "work", "home-gitea"])
    }

    func testRepoIsOptionalWhenAccountsPresent() throws {
        let cfg = try ConfigLoader.parse(
            """
            labels: [self-hosted]
            accounts:
              - {name: work, forge: github, scope: bigco}

            """)
        XCTAssertFalse(cfg.githubEnabled)
        XCTAssertEqual(cfg.allAccounts.map(\.name), ["work"])
        XCTAssertTrue(ConfigLoader.hasAnyForge(cfg))
    }

    func testRepoStillRequiredWithoutAccounts() {
        XCTAssertThrowsError(try ConfigLoader.parse("labels: [x]\n"))
    }

    func testRejectsBadAccounts() {
        let cases: [(String, String)] = [
            ("- {forge: github, scope: a}", "name is required"),
            ("- {name: Work, forge: github, scope: a}", "must be lowercase"),
            ("- {name: github, forge: github, scope: a}", "reserved"),
            ("- {name: a, forge: github, scope: x}\n  - {name: a, forge: github, scope: y}", "duplicate"),
            ("- {name: a, forge: bitbucket, scope: x}", "forge must be"),
            ("- {name: a, forge: github, scope: x/y/z}", "scope must be"),
            ("- {name: a, forge: gitea, scope: x}", "instance is required"),
            ("- {name: a, forge: gitea, scope: x, instance: 'https://h/api'}", "instance must be a base URL"),
            ("- {name: a, forge: github, scope: x, instance: 'https://h'}", "gitea accounts only"),
        ]
        for (entry, expected) in cases {
            XCTAssertThrowsError(try ConfigLoader.parse(base + "accounts:\n  \(entry)\n"), entry) { error in
                XCTAssertTrue("\(error.localizedDescription)".contains(expected), "\(entry): \(error)")
            }
        }
    }

    func testEngineTokenCountsExtraAccountTokens() throws {
        let cfg = try ConfigLoader.parse(
            """
            labels: [x]
            accounts:
              - {name: work, forge: github, scope: bigco}

            """)
        XCTAssertNil(ConfigLoader.engineToken(for: cfg, load: { _ in nil }, loadAccount: { _, _ in nil }))
        XCTAssertEqual(
            ConfigLoader.engineToken(for: cfg, load: { _ in nil }, loadAccount: { _, name in name == "work" ? "t" : nil }),
            "")
    }
}
