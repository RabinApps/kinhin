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
        XCTAssertTrue(helpText().contains("reset "), "the overview lists reset")
        let page = helpText(for: ["reset"])
        XCTAssertTrue(page.contains("reset [--scope config|daemon|all] [--yes]"), page)
        XCTAssertTrue(page.contains("no undo"), page)
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

    // MARK: - Leftovers

    func testLeftoversAreWarnedAndEndInNeedsAttention() {
        var plan = ResetPlan(scope: .all, supportRoot: URL(fileURLWithPath: "/tmp/kinhin-reset-cli"))
        plan.configBroken = true
        plan.configError = "bad YAML"
        let report = ResetReport(
            completed: ["removed the daemon LaunchAgent"],
            leftBehind: ["could not list Tart VMs (tart list failed); VMs and images were not removed"])
        let warnings = ResetCommand.warnings(plan: plan, report: report)
        XCTAssertEqual(
            warnings,
            [
                "the config could not be read (bad YAML); the tart path and image names came from the defaults",
                "could not list Tart VMs (tart list failed); VMs and images were not removed",
            ])
        XCTAssertTrue(ResetCommand.leftBehindSummary(report).contains("1 item(s) were left behind"))
        XCTAssertEqual(ExitRule.code(healthy: report.isComplete), .needsAttention)
        XCTAssertEqual(CLIExit.needsAttention.rawValue, 1)
    }

    func testACompleteResetHasNoWarningsAndExitsZero() {
        let plan = ResetPlan(scope: .config, supportRoot: URL(fileURLWithPath: "/tmp/kinhin-reset-cli"))
        let report = ResetReport(completed: ["removed config, logs and state"])
        XCTAssertEqual(ResetCommand.warnings(plan: plan, report: report), [])
        XCTAssertNil(ExitRule.code(healthy: report.isComplete))
    }

    func testABrokenConfigOnlyWarnsForTheEverythingScope() {
        var plan = ResetPlan(scope: .config, supportRoot: URL(fileURLWithPath: "/tmp/kinhin-reset-cli"))
        plan.configBroken = true
        XCTAssertEqual(
            ResetCommand.warnings(plan: plan, report: ResetReport()), [],
            "the config scope deletes the broken config; its defaults are never used")
    }
}
