import XCTest

@testable import KinhinKit
@testable import kinhin

/// The CLI side of `kinhin reset`: routing, scope resolution and the
/// confirmation contract. The wipe itself lives in `ResetEverythingTests`.
final class ResetCommandTests: XCTestCase {
    // MARK: - Routing

    func testResetIsARoutedCommand() {
        XCTAssertEqual(CLICommand.parse(["reset"]), .reset)
        XCTAssertEqual(CLICommand.parse(["reset", "--scope", "all"]), .reset)
    }

    func testResetNeverAutoCreatesAConfig() {
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.reset, args: ["reset"]))
    }

    func testHelpMentionsResetWithItsScopes() {
        let help = helpText()
        XCTAssertTrue(help.contains("reset [--scope config|daemon|all] [--yes]"), help)
        XCTAssertTrue(help.contains("no undo"), help)
    }

    // MARK: - Scope resolution

    func testScopeFlagParsesEveryScope() throws {
        XCTAssertEqual(try ResetCommand.resolveScope(args: ["--scope", "config"], interactive: false), .config)
        XCTAssertEqual(try ResetCommand.resolveScope(args: ["--scope", "daemon"], interactive: false), .daemon)
        XCTAssertEqual(try ResetCommand.resolveScope(args: ["--scope", "all"], interactive: false), .all)
    }

    func testUnknownScopeIsAUsageError() {
        XCTAssertThrowsError(try ResetCommand.resolveScope(args: ["--scope", "world"], interactive: false)) {
            error in
            guard let cliError = error as? CLIError else { return XCTFail("expected CLIError, got \(error)") }
            XCTAssertEqual(cliError.exit, .usage)
            XCTAssertTrue(cliError.message.contains("config, daemon, all"), cliError.message)
        }
    }

    func testMissingScopeWithoutATerminalIsAUsageErrorNotAHang() {
        // A non-interactive reset without --scope must refuse (exit 2) rather
        // than sit on a prompt it could never read.
        XCTAssertThrowsError(try ResetCommand.resolveScope(args: [], interactive: false)) { error in
            guard let cliError = error as? CLIError else { return XCTFail("expected CLIError, got \(error)") }
            XCTAssertEqual(cliError.exit, .usage)
            XCTAssertTrue(cliError.message.contains("--yes"), cliError.message)
        }
    }

    // MARK: - Confirmation contract

    func testTheConfirmationWordIsExact() {
        XCTAssertEqual(ResetCommand.confirmWord, "reset")
    }

    func testNextStepsPointAtTheWayBack() {
        XCTAssertTrue(ResetCommand.nextSteps(for: .config).contains("kinhin auth set"))
        XCTAssertTrue(ResetCommand.nextSteps(for: .all).contains("kinhin auth set"))
        XCTAssertTrue(ResetCommand.nextSteps(for: .daemon).contains("kinhin daemon install"))
    }
}
