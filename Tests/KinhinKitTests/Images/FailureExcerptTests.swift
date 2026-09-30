import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class FailureExcerptTests: XCTestCase {
    func testExcerptSkipsAptChatterAndKeepsTheRealError() {
        let stderr = """
            debconf: delaying package configuration, since apt-utils is not installed
            mise ERROR failed to install node@node@22
            mise ERROR invalid version: node@22
            """
        let excerpt = ShellResult(exitCode: 1, stdout: "", stderr: stderr).failureExcerpt
        XCTAssertFalse(excerpt.contains("debconf"))
        XCTAssertTrue(excerpt.contains("invalid version: node@22"), excerpt)
    }

    func testExcerptShowsTheTailOfALongLog() {
        let stderr = (1...50).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = ShellResult(exitCode: 1, stdout: "", stderr: stderr).failureExcerpt
        XCTAssertTrue(excerpt.hasSuffix("line 50"))
        XCTAssertFalse(excerpt.contains("line 1\n"))
    }

    func testExcerptSaysSoWhenThereIsNoUsefulOutput() {
        XCTAssertEqual(
            ShellResult(exitCode: 3, stdout: "", stderr: "").failureExcerpt, "no error output (exit 3)")
        XCTAssertEqual(
            ShellResult(exitCode: 3, stdout: "", stderr: "debconf: only noise").failureExcerpt, "exit 3")
    }
}
