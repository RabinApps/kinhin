import XCTest

@testable import KinhinKit

/// The routing rules of `WorkflowRouteEditor`: what is editable, how labels
/// are rewritten for a target pool (the stranded-job cases), and the
/// comment-preserving `runs-on:` surgery.
final class WorkflowRouteEditorTests: XCTestCase {
    private let containerPool = ["self-hosted", "macos", "arm64", "kinhin-container"]
    private let tartPool = ["self-hosted", "macos", "arm64"]
    private let amd64DockerPool = ["self-hosted", "x64", "kinhin-docker"]

    private func document(_ yaml: String) throws -> WorkflowDocument {
        try parseWorkflow(Data(yaml.utf8), at: URL(fileURLWithPath: "/tmp/kinhin-editor-test.yml"))
    }

    private let editableWorkflow = """
        name: CI
        on: [push]
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - run: echo hi
          test:
            runs-on: [self-hosted, macos]
            steps:
              - run: echo test
        """

    private let refusedWorkflow = """
        name: CI
        on: [push]
        jobs:
          matrix:
            runs-on: ${{ matrix.os }}
            steps:
              - run: echo hi
          grouped:
            runs-on: {group: macos, labels: [self-hosted]}
            steps:
              - run: echo hi
          template:
            uses: ./.github/workflows/reusable.yml
        """

    // MARK: - What is editable

    func testLabelListsAndScalarsAreEditable() throws {
        let doc = try document(editableWorkflow)
        XCTAssertEqual(doc.jobs.count, 2)
        XCTAssertTrue(WorkflowRouteEditor.canEdit(doc.jobs[0]))
        XCTAssertEqual(try WorkflowRouteEditor.labels(doc.jobs[0]), ["ubuntu-latest"])
        XCTAssertTrue(WorkflowRouteEditor.canEdit(doc.jobs[1]))
        XCTAssertEqual(try WorkflowRouteEditor.labels(doc.jobs[1]), ["self-hosted", "macos"])
    }

    func testExpressionMappingAndAbsentRunsOnAreRefused() throws {
        let doc = try document(refusedWorkflow)
        XCTAssertEqual(doc.jobs.count, 3)
        for job in doc.jobs {
            XCTAssertFalse(WorkflowRouteEditor.canEdit(job), "job '\(job.id)' must not be editable")
            XCTAssertThrowsError(try WorkflowRouteEditor.labels(job), "job '\(job.id)'") { error in
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                XCTAssertTrue(message.contains(job.id), message)
                XCTAssertTrue(message.contains("runs-on"), message)
                XCTAssertTrue(message.contains("route"), message)
            }
        }
    }

    // MARK: - Label rewriting (the stranded-job cases)

    func testMarkerIsAppendedAndKeptOnce() {
        XCTAssertEqual(
            WorkflowRouteEditor.editJobLabels(
                current: ["self-hosted", "macos"], runtime: .appleContainer, poolLabels: containerPool),
            ["self-hosted", "macos", "kinhin-container"])
        // Idempotent: a second run doesn't stack a duplicate marker.
        XCTAssertEqual(
            WorkflowRouteEditor.editJobLabels(
                current: ["self-hosted", "macos", "kinhin-container"], runtime: .appleContainer,
                poolLabels: containerPool),
            ["self-hosted", "macos", "kinhin-container"])
        XCTAssertEqual(
            WorkflowRouteEditor.editJobLabels(
                current: ["self-hosted"], runtime: .docker, poolLabels: amd64DockerPool),
            ["self-hosted", "kinhin-docker"])
    }

    func testGitHubHostedLabelsAreReplacedNotKept() {
        // `ubuntu-latest` can never be satisfied by kinhin's runners (the
        // forge AND-matches every label), so the pool's exact labels replace
        // it — routing marker included, runner match guaranteed.
        XCTAssertEqual(
            WorkflowRouteEditor.editJobLabels(
                current: ["ubuntu-latest"], runtime: .appleContainer, poolLabels: containerPool),
            containerPool)
        // Mixed lists keep what the pool can serve and drop what it can't.
        XCTAssertEqual(
            WorkflowRouteEditor.editJobLabels(
                current: ["self-hosted", "ubuntu-latest"], runtime: .docker, poolLabels: amd64DockerPool),
            ["self-hosted", "kinhin-docker"])
    }

    func testStaleMarkersAreStrippedForTart() {
        // tart is markerless: a leftover kinhin-* marker would strand the job
        // in the wrong pool once a tart route applies.
        XCTAssertEqual(
            WorkflowRouteEditor.editJobLabels(
                current: ["self-hosted", "kinhin-container"], runtime: .tart, poolLabels: tartPool),
            ["self-hosted"])
        XCTAssertEqual(
            WorkflowRouteEditor.editJobLabels(
                current: ["ubuntu-latest"], runtime: .tart, poolLabels: tartPool),
            tartPool)
        XCTAssertEqual(
            WorkflowRouteEditor.editJobLabels(
                current: ["self-hosted", "macos"], runtime: .tart, poolLabels: tartPool),
            ["self-hosted", "macos"])
    }

    // MARK: - runs-on: surgery

    func testApplyLabelEditReplacesTheLineAndPreservesTheRest() throws {
        let yaml = """
            name: CI            # the workflow-name comment stays
            on: [push]
            jobs:
              build:
                name: Build      # a comment on another key
                runs-on: ubuntu-latest   # pick our runner
                steps:
                  - run: echo hi
            """
        let edited = try WorkflowRouteEditor.applyLabelEdit(
            jobID: "build", labels: containerPool, in: yaml)
        XCTAssertTrue(edited.contains("name: CI            # the workflow-name comment stays"))
        XCTAssertTrue(edited.contains("name: Build      # a comment on another key"))
        XCTAssertTrue(edited.contains("runs-on: [self-hosted, macos, arm64, kinhin-container] # pick our runner"))
        let reparsed = try document(edited)
        XCTAssertEqual(try WorkflowRouteEditor.labels(reparsed.jobs[0]), containerPool)
    }

    func testBlockStyleRunsOnCollapsesToFlowAndStillParses() throws {
        let yaml = """
            name: CI
            on: [push]
            jobs:
              build:
                runs-on:
                  - self-hosted
                  - macos
                steps:
                  - run: echo hi
            """
        let edited = try WorkflowRouteEditor.applyLabelEdit(
            jobID: "build", labels: ["self-hosted", "macos", "kinhin-container"], in: yaml)
        XCTAssertTrue(edited.contains("runs-on: [self-hosted, macos, kinhin-container]"))
        XCTAssertFalse(edited.contains("- self-hosted"), "the old sequence must be consumed, not orphaned")
        let reparsed = try document(edited)
        XCTAssertEqual(try WorkflowRouteEditor.labels(reparsed.jobs[0]), ["self-hosted", "macos", "kinhin-container"])
    }

    func testInsertsRunsOnWhenTheJobHasNone() throws {
        let yaml = """
            name: CI
            on: [push]
            jobs:
              build:
                steps:
                  - run: echo hi
            """
        let edited = try WorkflowRouteEditor.applyLabelEdit(jobID: "build", labels: tartPool, in: yaml)
        XCTAssertTrue(edited.contains("    runs-on: [self-hosted, macos, arm64]"))
        let reparsed = try document(edited)
        XCTAssertEqual(try WorkflowRouteEditor.labels(reparsed.jobs[0]), tartPool)
    }

    func testUnknownJobIsRefused() {
        XCTAssertThrowsError(
            try WorkflowRouteEditor.applyLabelEdit(jobID: "nope", labels: tartPool, in: editableWorkflow)
        ) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("nope"), message)
        }
    }

    func testLabelsNeedingQuotesAreQuotedInFlowLists() throws {
        let edited = try WorkflowRouteEditor.applyLabelEdit(
            jobID: "test", labels: ["self-hosted", "mac runner"], in: editableWorkflow)
        XCTAssertTrue(edited.contains("runs-on: [self-hosted, \"mac runner\"]"), edited)
        let reparsed = try document(edited)
        XCTAssertEqual(try WorkflowRouteEditor.labels(reparsed.jobs[1]), ["self-hosted", "mac runner"])
    }
}
