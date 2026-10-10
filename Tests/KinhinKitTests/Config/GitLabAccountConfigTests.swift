import XCTest

@testable import KinhinKit

/// `forge: gitlab` entries in `accounts:` (GitLab has no top-level section).
final class GitLabAccountConfigTests: XCTestCase {
    private func parse(_ account: String) throws -> KinhinConfig {
        try ConfigLoader.parse(
            """
            labels: [macos]
            accounts:
            \(account)
            """)
    }

    func testNestedScopeDefaultsToGitLabDotCom() throws {
        let cfg = try parse(
            """
              - name: gitlab
                forge: gitlab
                scope: acme/platform/api
            """)
        let account = try XCTUnwrap(cfg.accounts.first)
        XCTAssertEqual(account.forge, .gitlab)
        XCTAssertEqual(account.scope, "acme/platform/api", "GitLab paths nest")
        XCTAssertNil(account.instance, "absent → gitlab.com")
        XCTAssertNil(account.labels, "absent → the top-level labels")
        XCTAssertEqual(cfg.allAccounts.map(\.name), ["gitlab"], "'gitlab' is an ordinary account name")
    }

    func testSelfManagedInstanceAndLabels() throws {
        let cfg = try parse(
            """
              - name: work
                forge: gitlab
                scope: platform
                instance: https://git.example.com/gitlab
                labels: [macos, arm64]
            """)
        XCTAssertEqual(cfg.accounts.first?.instance, "https://git.example.com/gitlab")
        XCTAssertEqual(cfg.accounts.first?.labels, ["macos", "arm64"])
    }

    func testRejectsBadInstanceEmptyLabelsAndEmptySegments() {
        XCTAssertThrowsError(
            try parse(
                """
                  - name: gl
                    forge: gitlab
                    scope: acme
                    instance: https://git.example.com/api/v4
                """))
        XCTAssertThrowsError(
            try parse(
                """
                  - name: gl
                    forge: gitlab
                    scope: acme
                    labels: []
                """))
        XCTAssertThrowsError(
            try parse(
                """
                  - name: gl
                    forge: gitlab
                    scope: acme//api
                """))
    }

    /// A GitLab runner takes one job and deletes itself; a persistent VM
    /// would idle forever behind it, so the config is rejected up front.
    func testRejectsNonEphemeralVMs() {
        XCTAssertThrowsError(
            try ConfigLoader.parse(
                """
                labels: [macos]
                vm:
                  ephemeral: false
                accounts:
                  - name: gl
                    forge: gitlab
                    scope: acme/api
                """)
        ) { error in
            XCTAssertTrue("\(error)".contains("vm.ephemeral"), "\(error)")
        }
    }

    func testNonEphemeralVMsRemainValidForOtherForges() throws {
        let cfg = try ConfigLoader.parse(
            """
            labels: [macos]
            vm:
              ephemeral: false
            accounts:
              - name: gh
                forge: github
                scope: acme/api
            """)
        XCTAssertFalse(cfg.vm.ephemeral)
    }

    func testOtherForgesStillTakeTwoSegmentsAtMost() {
        XCTAssertThrowsError(
            try parse(
                """
                  - name: gh
                    forge: github
                    scope: acme/platform/api
                """))
    }
}
