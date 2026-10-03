import Foundation
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport
@testable import kinhin_app

@MainActor
final class WorkflowTestModelTests: XCTestCase {
    func testChoosesParsesAndRunsWorkflow() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-model-\(UUID().uuidString).yml")
        try Data("jobs:\n  test:\n    steps:\n      - run: echo hello\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let shell = FakeShell()
        shell.defaultResult = ShellResult(exitCode: 0, stdout: "hello\n", stderr: "")
        let model = WorkflowTestModel(chooseFile: { file }, shell: shell)

        await model.chooseWorkflow()
        XCTAssertEqual(model.workflowName, file.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(model.jobs, ["test"])
        await model.start()
        XCTAssertEqual(model.state, .succeeded)
        XCTAssertEqual(model.report?.overallState, .succeeded)
        XCTAssertEqual(model.stepOutput, "hello\n")
    }

    func testParseFailureIsSurfaced() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-invalid-\(UUID().uuidString).yml")
        try Data("not: [valid".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = WorkflowTestModel(chooseFile: { file }, shell: FakeShell())
        await model.chooseWorkflow()
        XCTAssertNil(model.document)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.state, .idle)
    }
}
