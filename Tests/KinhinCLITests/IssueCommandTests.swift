import KinhinKit
import XCTest

@testable import kinhin

final class IssueCommandTests: XCTestCase {
    func testIssueRoutesAndResolvesItsFlags() throws {
        XCTAssertEqual(CLICommand.parse(["issue"]), .issue)
        let invocation = try CommandResolver.resolve(["issue", "--print", "--json"])
        XCTAssertEqual(invocation.command, .issue)
        XCTAssertTrue(invocation.json)
        XCTAssertThrowsError(try CommandResolver.resolve(["issue", "--bogus"])) { error in
            XCTAssertEqual((error as? CLIError)?.exit, .usage)
        }
    }

    func testIssueNeverCreatesTheStarterConfig() {
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.issue))
    }

    func testIssueLinkPointsAtTheRepoIssueChooser() {
        XCTAssertEqual(
            SupportLinks.reportAnIssue.url.absoluteString,
            "https://github.com/RabinApps/kinhin/issues/new/choose")
    }
}
