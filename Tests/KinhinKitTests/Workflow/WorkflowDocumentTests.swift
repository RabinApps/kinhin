import Foundation
import XCTest

@testable import KinhinKit

final class WorkflowDocumentTests: XCTestCase {
    func testParsesJobsEnvironmentDefaultsAndStepMetadata() throws {
        let url = URL(fileURLWithPath: "/repo/.github/workflows/ci.yml")
        let workflow = try parseWorkflow(
            Data(
                """
                name: CI
                env:
                  GLOBAL: yes
                defaults:
                  run:
                    shell: bash
                    working-directory: Sources
                jobs:
                  build:
                    needs: [lint]
                    env:
                      JOB_VALUE: two
                    timeout-minutes: 12
                    continue-on-error: true
                    strategy:
                      matrix:
                        os: [macos-latest, ubuntu-latest]
                    steps:
                      - run: echo hello
                        if: ${{ success() }}
                        timeout-minutes: 2
                        continue-on-error: true
                        working-directory: Tests
                      - uses: actions/checkout@v4
                  lint:
                    steps:
                      - name: Check
                        run: swift test
                """.utf8), at: url)

        XCTAssertEqual(workflow.name, "CI")
        XCTAssertEqual(workflow.env["GLOBAL"], "yes")
        XCTAssertEqual(workflow.defaults?.run?.shell, "bash")
        XCTAssertEqual(workflow.defaults?.run?.workingDirectory, "Sources")
        XCTAssertEqual(workflow.jobs.map(\.id), ["build", "lint"])
        let build = try XCTUnwrap(workflow.jobs.first)
        XCTAssertEqual(build.name, "build")
        XCTAssertEqual(build.needs, ["lint"])
        XCTAssertEqual(build.timeoutMinutes, 12)
        XCTAssertTrue(build.continueOnError)
        XCTAssertTrue(build.hasMatrix)
        XCTAssertEqual(build.steps[0].name, "Run echo hello")
        XCTAssertEqual(build.steps[0].condition, "${{ success() }}")
        XCTAssertEqual(build.steps[0].workingDirectory, "Tests")
        XCTAssertEqual(build.steps[0].timeoutMinutes, 2)
        XCTAssertTrue(build.steps[0].continueOnError)
        XCTAssertEqual(build.steps[1].name, "actions/checkout@v4")
    }

    func testReportsInvalidYamlAndNoJobs() {
        let url = URL(fileURLWithPath: "/tmp/workflow.yml")
        XCTAssertThrowsError(try parseWorkflow(Data("jobs: [".utf8), at: url)) { error in
            XCTAssertTrue(error is WorkflowError)
        }
        XCTAssertThrowsError(try parseWorkflow(Data("name: empty\n".utf8), at: url)) { error in
            XCTAssertEqual(error.localizedDescription, "workflow.yml defines no jobs")
        }
    }

    func testLocatesSingleWorkflowAndRejectsAmbiguity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-discovery-\(UUID().uuidString)")
        let workflows = root.appendingPathComponent(".github/workflows", isDirectory: true)
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = workflows.appendingPathComponent("ci.yml")
        try Data("jobs: {}".utf8).write(to: first)
        XCTAssertEqual(canonicalPath(try locateWorkflow(in: root)), canonicalPath(first))
        try Data("jobs: {}".utf8).write(to: workflows.appendingPathComponent("release.yaml"))
        XCTAssertThrowsError(try locateWorkflow(in: root)) { error in
            guard case WorkflowError.ambiguousWorkflow(let names) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(names, ["ci.yml", "release.yaml"])
        }
    }

    /// Directory listings report `/private/var/…` while URLs built from
    /// `temporaryDirectory` stay `/var/…` (Foundation strips the `/private`
    /// prefix when it standardizes a path), so compare the two forms with the
    /// prefix removed rather than relying on symlink resolution.
    private func canonicalPath(_ url: URL) -> String {
        url.path.hasPrefix("/private") ? String(url.path.dropFirst("/private".count)) : url.path
    }
}
