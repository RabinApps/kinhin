import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class BenchmarkRegistryTests: XCTestCase {
    private var harness: BenchHarness!

    override func setUp() {
        super.setUp()
        harness = BenchHarness()
    }

    override func tearDown() {
        harness.cleanUp()
        super.tearDown()
    }

    func testAStartedRunFinishesWithItsReportAndProgress() async throws {
        let registry = BenchmarkRegistry()
        let id = try registry.start(
            options: BenchmarkOptions(suites: [.boot], runtimes: [.tart]), environment: harness.makeEnvironment())
        XCTAssertEqual(registry.status(runID: id)?.runID, id)
        await registry.wait(runID: id)

        let status = try XCTUnwrap(registry.status(runID: id))
        XCTAssertEqual(status.state, .finished)
        XCTAssertEqual(status.report?.runID, id)
        XCTAssertEqual(status.progress.completed.map(\.name), ["boot"])
        XCTAssertNil(status.error)
        XCTAssertEqual(registry.status(runID: nil)?.runID, id, "no id means the latest run")
    }

    func testAFailedRunReportsItsError() async throws {
        harness.missingImages = [.tart]
        let registry = BenchmarkRegistry()
        let id = try registry.start(
            options: BenchmarkOptions(suites: [.boot], runtimes: [.tart]), environment: harness.makeEnvironment())
        await registry.wait(runID: id)
        let status = try XCTUnwrap(registry.status(runID: id))
        XCTAssertEqual(status.state, .failed)
        XCTAssertTrue(status.error?.contains("kinhin image prepare") == true, status.error ?? "")
        XCTAssertNil(status.report)
    }

    func testOnlyOneRunAtATime() async throws {
        harness.ssh.blockOnCall(0)
        let registry = BenchmarkRegistry()
        let first = try registry.start(
            options: BenchmarkOptions(suites: [.boot], runtimes: [.tart]), environment: harness.makeEnvironment())
        await harness.ssh.waitUntilBlocked()
        XCTAssertThrowsError(
            try registry.start(
                options: BenchmarkOptions(suites: [.boot], runtimes: [.tart]), environment: harness.makeEnvironment())
        ) { error in
            guard case BenchmarkError.alreadyRunning(let running) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(running, first)
        }
        XCTAssertEqual(registry.status(runID: first)?.state, .running)
        harness.ssh.releaseBlocked()
        await registry.wait(runID: first)
        XCTAssertEqual(registry.status(runID: first)?.state, .finished)
    }

    func testCancellingMarksTheRunCancelledAndCleansUp() async throws {
        harness.ssh.blockOnCall(0)
        let registry = BenchmarkRegistry()
        let id = try registry.start(
            options: BenchmarkOptions(suites: [.boot], runtimes: [.tart]), environment: harness.makeEnvironment())
        await harness.ssh.waitUntilBlocked()
        registry.cancel(runID: id)
        harness.ssh.releaseBlocked()
        await registry.wait(runID: id)
        XCTAssertEqual(registry.status(runID: id)?.state, .cancelled)
        XCTAssertTrue(harness.tart.vms.isEmpty)
    }

    func testInvalidOptionsAreRejectedBeforeAnythingStarts() {
        XCTAssertThrowsError(
            try BenchmarkRegistry().start(
                options: BenchmarkOptions(iterations: 0), environment: harness.makeEnvironment()))
        XCTAssertTrue(harness.tart.cloneCalls.isEmpty)
    }

    func testUnknownRunsHaveNoStatus() {
        XCTAssertNil(BenchmarkRegistry().status(runID: "bench-nope"))
        XCTAssertNil(BenchmarkRegistry().status(runID: nil))
    }

    func testStatusCodableRoundTrip() throws {
        let status = BenchmarkRunStatus(
            runID: "bench-1", state: .running,
            progress: BenchmarkProgress(phase: "running", suite: "boot", runtime: "tart", step: "clone"),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), elapsedSeconds: 12)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(BenchmarkRunStatus.self, from: encoder.encode(status)), status)
        XCTAssertEqual(status.progress.line, "boot › tart › clone")
    }
}
