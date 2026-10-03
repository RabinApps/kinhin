import XCTest

@testable import kinhin

final class WorkflowTestCommandTests: XCTestCase {
    func testParsesSupportedOptions() throws {
        let options = try WorkflowTestCommand.parse([".github/workflows/ci.yml", "--job", "build", "--json"])
        XCTAssertEqual(options.file?.path, URL(fileURLWithPath: ".github/workflows/ci.yml").path)
        XCTAssertEqual(options.job, "build")
        XCTAssertTrue(options.json)
        XCTAssertFalse(options.list)
    }

    func testRejectsDuplicateFilesAndMissingJobName() {
        XCTAssertThrowsError(try WorkflowTestCommand.parse(["one.yml", "two.yml"]))
        XCTAssertThrowsError(try WorkflowTestCommand.parse(["--job"]))
        XCTAssertThrowsError(try WorkflowTestCommand.parse(["--unsupported"]))
    }

    func testWorkflowRoutingDoesNotCreateConfig() {
        XCTAssertEqual(CLICommand.parse(["workflow", "test"]), .workflow)
        XCTAssertFalse(CLICommand.shouldAutoCreateConfig(.workflow, args: ["workflow", "test"]))
        XCTAssertTrue(helpText().contains("workflow test [FILE]"))
    }
}
