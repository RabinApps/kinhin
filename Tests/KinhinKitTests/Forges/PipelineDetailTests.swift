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

/// Live timing text shared by the app and the CLI.
final class PipelineFormatterTimingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    func testAgo() {
        XCTAssertEqual(PipelineFormatter.ago(t0, now: t0.addingTimeInterval(1)), "just now")
        XCTAssertEqual(PipelineFormatter.ago(t0, now: t0.addingTimeInterval(-30)), "just now", "clock skew")
        XCTAssertEqual(PipelineFormatter.ago(t0, now: t0.addingTimeInterval(42)), "42s ago")
        XCTAssertEqual(PipelineFormatter.ago(t0, now: t0.addingTimeInterval(125)), "2m ago")
        XCTAssertEqual(PipelineFormatter.ago(t0, now: t0.addingTimeInterval(7_300)), "2h ago")
        XCTAssertEqual(PipelineFormatter.ago(t0, now: t0.addingTimeInterval(200_000)), "2d ago")
    }

    func testTimingTicksWithTheClockWhileRunning() {
        let now1 = t0.addingTimeInterval(10)
        let now2 = t0.addingTimeInterval(70)
        XCTAssertEqual(
            PipelineFormatter.timing(state: .running, startedAt: t0, finishedAt: nil, now: now1),
            "10s · started 10s ago")
        XCTAssertEqual(
            PipelineFormatter.timing(state: .running, startedAt: t0, finishedAt: nil, now: now2),
            "1m 10s · started 1m ago")
    }

    func testFinishedTimingFreezesTheDurationAndAgesTheFinish() {
        let done = t0.addingTimeInterval(30)
        XCTAssertEqual(
            PipelineFormatter.timing(
                state: .succeeded, startedAt: t0, finishedAt: done, now: done.addingTimeInterval(90)),
            "30s · finished 1m ago")
        XCTAssertNil(PipelineFormatter.timing(state: .pending, startedAt: nil, finishedAt: nil))
    }
}
