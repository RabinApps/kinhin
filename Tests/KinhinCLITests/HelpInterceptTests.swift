import XCTest

@testable import kinhin

/// `--help`/`-h` after any command prints that command's help instead of
/// running it (`kinhin stop --help` used to stop the fleet).
final class HelpInterceptTests: XCTestCase {
    func testHelpFlagAfterEveryCommandPrintsHelpInsteadOfRunning() throws {
        for spec in CommandCatalog.all where !spec.hidden && spec.name != "help" && spec.name != "version" {
            for flag in ["--help", "-h"] {
                let invocation = try CommandResolver.resolve([spec.name, flag])
                XCTAssertTrue(invocation.wantsHelp, "\(spec.name) \(flag)")
                XCTAssertEqual(invocation.helpPath, [spec.name])
            }
        }
    }

    func testHelpFlagAfterASubcommandDocumentsTheSubcommand() throws {
        let invocation = try CommandResolver.resolve(["image", "prepare", "--container", "--help"])
        XCTAssertTrue(invocation.wantsHelp)
        XCTAssertEqual(invocation.helpPath, ["image", "prepare"])
        // Even when the command line is otherwise incomplete.
        XCTAssertTrue(try CommandResolver.resolve(["workflow", "--help"]).wantsHelp)
        XCTAssertTrue(try CommandResolver.resolve(["reset", "--help"]).wantsHelp)
    }

    func testPlainInvocationsAreNotIntercepted() throws {
        XCTAssertFalse(try CommandResolver.resolve(["stop"]).wantsHelp)
        XCTAssertFalse(try CommandResolver.resolve(["auth", "set"]).wantsHelp)
    }

    func testHelpTopicPrintsThatCommandsPage() {
        XCTAssertTrue(helpText(for: ["cleanup"]).hasPrefix("kinhin cleanup — "))
        XCTAssertTrue(helpText(for: ["image", "ls"]).hasPrefix("kinhin image list — "))
        // An unknown topic falls back to the full screen.
        XCTAssertEqual(helpText(for: ["nonsense"]), helpText())
        XCTAssertEqual(helpText(for: []), helpText())
    }
}
