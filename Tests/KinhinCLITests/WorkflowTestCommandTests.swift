import XCTest

@testable import KinhinKit
@testable import kinhin

final class WorkflowTestCommandTests: XCTestCase {
    func testParsesSupportedOptions() throws {
        let options = try WorkflowTestCommand.parse([".github/workflows/ci.yml", "--job", "build", "--json"])
        XCTAssertEqual(options.file?.path, URL(fileURLWithPath: ".github/workflows/ci.yml").path)
        XCTAssertEqual(options.job, "build")
        XCTAssertTrue(options.json)
        XCTAssertFalse(options.list)
    }

    func testParsesLenientAndDefaultsToStrict() throws {
        XCTAssertTrue(try WorkflowTestCommand.parse(["--lenient"]).lenient)
        XCTAssertFalse(try WorkflowTestCommand.parse([]).lenient)
    }

    func testSummaryLineNamesPartialAndTheUnsupportedCount() {
        let skipped = LocalStepResult(
            name: "deploy", state: .skipped, startedAt: nil, finishedAt: nil, duration: nil,
            notices: ["uses: acme/deploy@v1 skipped"], skippedAsUnsupported: true)
        let job = LocalJobResult(
            name: "ci", state: .succeeded, startedAt: nil, finishedAt: nil, duration: 0, steps: [skipped])
        let report = LocalRunReport(
            workflowPath: URL(fileURLWithPath: "/repo/ci.yml"), workflowName: "ci", workingDirectory: "/repo",
            startedAt: Date(), finishedAt: Date(), jobs: [job], notices: [])
        XCTAssertEqual(
            WorkflowTestCommand.summaryLine(for: report), "summary: partial · 1 job(s) · 1 skipped as unsupported")
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
