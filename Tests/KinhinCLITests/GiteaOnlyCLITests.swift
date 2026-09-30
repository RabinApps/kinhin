import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class GiteaOnlyCLITests: XCTestCase {
    private let giteaOnly = try! ConfigLoader.parse(
        """
        labels: [a]
        accounts:
          - name: gitea
            forge: gitea
            scope: "team/repo"
            instance: "https://git.example.com"
        """)

    func testAuthStatusIsGoodWithOnlyTheGiteaToken() {
        let report = AuthStatusReporter.report(
            config: giteaOnly, load: { _ in nil }, loadAccount: { forge, _ in forge == .gitea ? "gt-token" : nil })
        XCTAssertTrue(report.allGood, "a Gitea-only config needs no GitHub token")
        XCTAssertFalse(report.forges.first { $0.id == "github" }!.configured)
    }

    func testAuthStatusNotGoodWithoutTheGiteaToken() {
        let report = AuthStatusReporter.report(
            config: giteaOnly, load: { _ in nil }, loadAccount: { forge, _ in forge == .github ? "gh" : nil })
        XCTAssertFalse(report.allGood)
    }

    func testSetupChecklistHasNoGitHubRowForGiteaOnly() async {
        let status = await SetupStatusComputer(
            clt: .ok(version: "15"), tartHealth: .healthy, config: .loaded(giteaOnly),
            accountTokensStored: ["gitea": true]
        ).compute()
        XCTAssertNil(status.checks.first { $0.id == "account-token-github" })
        XCTAssertEqual(status.checks.first { $0.id == "account-token-gitea" }?.ok, true)
        XCTAssertEqual(status.checks.first { $0.id == "config" }?.ok, true)
    }
}

/// GitHub and Gitea served by one engine at the same time.
