import XCTest

@testable import KinhinKit

final class AuthStatusAccountsTests: XCTestCase {
    private let config = try! ConfigLoader.parse(
        """
        repo: acme/widgets
        labels: [a]
        accounts:
          - {name: work, forge: github, scope: bigco}

        """)

    func testReportListsAccountsAndKeepsLegacyForges() {
        let report = AuthStatusReporter.report(
            config: config, load: { _ in "ghp_legacy" }, loadAccount: { _, _ in "ghp_work" })
        XCTAssertEqual(report.forges.map(\.id), ["github", "gitea"])
        XCTAssertEqual(report.accounts.map(\.name), ["work"])
        XCTAssertEqual(report.accounts.first?.prefix, "ghp_")
        XCTAssertTrue(report.allGood)
    }

    func testAMissingAccountTokenMakesTheReportNotGood() {
        let report = AuthStatusReporter.report(config: config, load: { _ in "t" }, loadAccount: { _, _ in nil })
        XCTAssertFalse(report.allGood)
        XCTAssertTrue(report.accounts.first?.detail.contains("kinhin auth set --account work") == true)
    }

    func testAccountsOnlyConfigIsGoodWithJustAccountTokens() throws {
        let cfg = try ConfigLoader.parse(
            "labels: [a]\naccounts:\n  - {name: work, forge: github, scope: bigco}\n")
        let report = AuthStatusReporter.report(config: cfg, load: { _ in nil }, loadAccount: { _, _ in "t" })
        XCTAssertTrue(report.allGood)
    }

    func testOldJSONWithoutAccountsStillDecodes() throws {
        let json = #"{"forges":[],"allGood":false}"#
        let report = try JSONDecoder().decode(AuthStatusReport.self, from: Data(json.utf8))
        XCTAssertTrue(report.accounts.isEmpty)
    }
}
