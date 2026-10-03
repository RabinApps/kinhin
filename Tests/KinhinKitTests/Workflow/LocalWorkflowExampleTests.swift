import Foundation
import XCTest

@testable import KinhinKit

final class LocalWorkflowExampleTests: XCTestCase {
    func testDocumentedLocalSmokeWorkflowExample() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/workflow-local-smoke.yml")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-doc-example-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workflow = try parseWorkflow(Data(contentsOf: fixture), at: fixture)
        let report = try await LocalWorkflowRunner(shell: Shell()).run(document: workflow, workingDirectory: root)

        XCTAssertEqual(report.overallState, .succeeded)
        XCTAssertEqual(report.jobs.map(\.name), ["Local smoke test"])
        XCTAssertEqual(report.jobs.first?.steps.first?.state, .succeeded)
        XCTAssertEqual(
            report.jobs.first?.steps.first?.output?.trimmingCharacters(in: .whitespacesAndNewlines),
            "Hello, from macOS (arm64)")
    }
}
