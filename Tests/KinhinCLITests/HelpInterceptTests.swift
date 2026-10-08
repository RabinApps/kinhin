import XCTest

@testable import kinhin

final class HelpInterceptTests: XCTestCase {
    func testHelpFlagAfterRunCommandsPrintsHelpInsteadOfRunning() {
        for name in ["stop", "pause", "resume", "status", "start", "daemon", "cleanup"] {
            let args = [name, "--help"]
            XCTAssertTrue(CLICommand.wantsHelp(CLICommand.parse(args), args: args), name)
            let short = [name, "-h"]
            XCTAssertTrue(CLICommand.wantsHelp(CLICommand.parse(short), args: short), name)
        }
    }

    func testPlainInvocationsAreNotIntercepted() {
        XCTAssertFalse(CLICommand.wantsHelp(CLICommand.parse(["stop"]), args: ["stop"]))
        XCTAssertFalse(CLICommand.wantsHelp(nil, args: ["bogus", "--help"]))
        // Commands with their own --help handling keep it.
        XCTAssertFalse(CLICommand.wantsHelp(.reset, args: ["reset", "--help"]))
    }
}
