import XCTest

@testable import KinhinKit

final class AccountsConfigTests: XCTestCase {
    private let base = """
        accounts:
          - name: github
            forge: github
            scope: acme/widgets
        labels: [self-hosted]

        """

    func testParsesExplicitAccounts() throws {
        let cfg = try ConfigLoader.parse(
            """
            accounts:
              - name: work
                forge: github
                scope: bigco
              - name: home-gitea
                forge: gitea
                scope: me/repo
                instance: https://git.home.lan
                labels: [macos:host]
            labels: [self-hosted]
            """)
        XCTAssertEqual(cfg.accounts.count, 2)
        XCTAssertEqual(
            cfg.accounts.first { $0.name == "work" }, AccountConfig(name: "work", forge: .github, scope: "bigco"))
        XCTAssertEqual(cfg.accounts.first { $0.name == "home-gitea" }?.instance, "https://git.home.lan")
        XCTAssertEqual(cfg.allAccounts.map(\.name), ["work", "home-gitea"])
    }

    func testGiteaAccountEnablesItsForge() throws {
        let cfg = try ConfigLoader.parse(
            """
            labels: [self-hosted]
            accounts:
              - {name: work, forge: github, scope: bigco}

            """)
        XCTAssertTrue(cfg.githubEnabled)
        XCTAssertTrue(ConfigLoader.hasAnyForge(cfg))
    }

    func testEmptyAccountsIsTheTemplateState() throws {
        // The starter template parses (the checklist classifies it) but no
        // forge is configured yet.
        let cfg = try ConfigLoader.parse("labels: [x]\n")
        XCTAssertTrue(cfg.accounts.isEmpty)
        XCTAssertFalse(ConfigLoader.hasAnyForge(cfg))
    }

    func testRejectsBadAccounts() {
        let cases: [(String, String)] = [
            ("- {forge: github, scope: a}", "name is required"),
            ("- {name: Work, forge: github, scope: a}", "must be lowercase"),
            ("- {name: a, forge: github, scope: x}\n  - {name: a, forge: github, scope: y}", "duplicate"),
            ("- {name: a, forge: bitbucket, scope: x}", "forge must be"),
            ("- {name: a, forge: github, scope: x/y/z}", "scope must be"),
            ("- {name: a, forge: gitea, scope: x}", "instance is required"),
            ("- {name: a, forge: gitea, scope: x, instance: 'https://h/api'}", "instance must be a base URL"),
        ]
        for (entry, expected) in cases {
            let yaml = "labels: [self-hosted]\naccounts:\n  \(entry)\n"
            XCTAssertThrowsError(try ConfigLoader.parse(yaml), entry) { error in
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
        XCTAssertNil(try ConfigLoader.engineToken(for: cfg, loadAccount: { _, _ in nil }))
        XCTAssertEqual(
            try ConfigLoader.engineToken(
                for: cfg, loadAccount: { _, name in name == "work" ? "t" : nil }),
            "")
    }
}
