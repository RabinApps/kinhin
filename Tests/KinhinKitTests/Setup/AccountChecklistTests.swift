import XCTest

@testable import KinhinKit

final class AccountChecklistTests: XCTestCase {
    private let config = try! ConfigLoader.parse(
        """
        repo: acme/widgets
        labels: [a]
        accounts:
          - {name: work, forge: github, scope: bigco}
          - {name: home, forge: gitea, scope: me, instance: "https://git.lan"}

        """)

    private func status(_ stored: [String: Bool]) async -> SetupStatus {
        await SetupStatusComputer(
            host: HostResources(logicalCores: 10, memoryGB: 64, freeDiskGB: 120, arm64: true),
            clt: .ok(version: "15"), tartHealth: .healthy, tartList: [], config: .loaded(config),
            tokenStored: true, giteaTokenStored: false, accountTokensStored: stored
        ).compute()
    }

    func testEachAccountGetsATokenRow() async {
        let result = await status(["work": true, "home": false])
        let work = result.checks.first { $0.id == "account-token-work" }
        let home = result.checks.first { $0.id == "account-token-home" }
        XCTAssertEqual(work?.ok, true)
        XCTAssertEqual(work?.action, "replace_account_token")
        XCTAssertEqual(home?.ok, false)
        XCTAssertEqual(home?.action, "enter_account_token")
        XCTAssertTrue(home?.detail.contains("kinhin auth set --account home") == true)
        XCTAssertFalse(result.ready, "a missing account token blocks readiness")
    }

    func testConfigRowMentionsTheExtraAccounts() async {
        let result = await status(["work": true, "home": true])
        XCTAssertTrue(result.checks.first { $0.id == "config" }?.detail.contains("+ 2 more accounts") == true)
    }

    func testEveryAccountActionIsTitledAndHandled() {
        for action in ["enter_account_token", "replace_account_token"] {
            XCTAssertNotEqual(SetupAction.title(for: action), action)
            XCTAssertTrue(ActionCoverageTests.handledActions.contains(action))
        }
    }
}
