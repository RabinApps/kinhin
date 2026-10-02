import XCTest

@testable import KinhinKit

/// The forge-neutral pipeline value: aggregation, status mapping and the wire
/// round trip the daemon RPC relies on.
final class PipelineDetailTests: XCTestCase {
    func testAggregateStates() {
        XCTAssertEqual(PipelineDetail.aggregate([]), .pending)
        XCTAssertEqual(PipelineDetail.aggregate([.succeeded, .succeeded]), .succeeded)
        XCTAssertEqual(PipelineDetail.aggregate([.succeeded, .running]), .running)
        XCTAssertEqual(PipelineDetail.aggregate([.succeeded, .pending]), .running, "between jobs it is still running")
        XCTAssertEqual(PipelineDetail.aggregate([.pending, .pending]), .pending)
        XCTAssertEqual(PipelineDetail.aggregate([.succeeded, .failed]), .failed)
        XCTAssertEqual(PipelineDetail.aggregate([.succeeded, .cancelled]), .cancelled)
    }

    func testStatusConclusionMapping() {
        XCTAssertEqual(PipelineParsing.state(status: "queued", conclusion: nil), .pending)
        XCTAssertEqual(PipelineParsing.state(status: "in_progress", conclusion: nil), .running)
        XCTAssertEqual(PipelineParsing.state(status: "completed", conclusion: "success"), .succeeded)
        XCTAssertEqual(PipelineParsing.state(status: "completed", conclusion: "timed_out"), .failed)
        XCTAssertEqual(PipelineParsing.state(status: "completed", conclusion: "skipped"), .skipped)
        XCTAssertEqual(PipelineParsing.state(status: "completed", conclusion: "cancelled"), .cancelled)
    }

    func testDatesParseWithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(PipelineParsing.date("2026-10-02T10:00:00Z"))
        XCTAssertNotNil(PipelineParsing.date("2026-10-02T10:00:00.123Z"))
        XCTAssertNil(PipelineParsing.date("yesterday"))
        XCTAssertNil(PipelineParsing.date(nil))
    }

    func testRoundTripsThroughJSON() throws {
        let detail = PipelineDetail(
            forge: .buildkite, title: "iOS #1", state: .running,
            jobs: [
                PipelineJob(
                    id: "j", name: "Test", state: .running, startedAt: Date(timeIntervalSince1970: 100),
                    steps: [PipelineStep(name: "run", state: .running)], isCurrent: true)
            ], granularity: .job, fetchedAt: Date(timeIntervalSince1970: 200))
        let decoded = try JSONDecoder().decode(PipelineDetail.self, from: JSONEncoder().encode(detail))
        XCTAssertEqual(decoded, detail)
        XCTAssertEqual(decoded.currentJob?.id, "j")
    }
}
