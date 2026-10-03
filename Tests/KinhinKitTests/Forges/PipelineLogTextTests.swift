import XCTest

@testable import KinhinKit

/// Cleaning raw forge logs for display and slicing a GitHub job log per step.
final class PipelineLogTextTests: XCTestCase {
    func testCleanStripsEscapesTimestampsAndSectionMarkers() {
        let raw =
            "\u{1B}[32mgreen\u{1B}[0m text\n"
            + "\u{1B}_bk;t=1700000000\u{07}buildkite line\n"
            + "section_start:1700000000:build_script\r\u{1B}[0Kstep one\n"
            + "section_end:1700000001:build_script\r\u{1B}[0Kdone\n"
        let (text, truncated) = PipelineLogText.clean(raw)
        XCTAssertEqual(text, "green text\nbuildkite line\nstep one\ndone\n")
        XCTAssertFalse(truncated)
    }

    func testCarriageReturnKeepsTheLastProgressState() {
        let (text, _) = PipelineLogText.clean("10%\r50%\r100%\ndone\n")
        XCTAssertEqual(text, "100%\ndone\n")
    }

    func testCleanKeepsOnlyTheTailAtALineBoundary() {
        let raw = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let (text, truncated) = PipelineLogText.clean(raw, limit: 60)
        XCTAssertTrue(truncated)
        XCTAssertTrue(text.hasSuffix("line 100"))
        XCTAssertTrue(text.hasPrefix("line "), "starts on a whole line: \(text.prefix(12))")
        XCTAssertLessThanOrEqual(text.count, 60)
    }

    func testTimestampParsing() throws {
        let line = Substring("2026-10-02T10:00:01.5000000Z hello")
        let stamp = try XCTUnwrap(PipelineLogText.timestamp(of: line))
        let base = try XCTUnwrap(PipelineParsing.date("2026-10-02T10:00:01Z"))
        XCTAssertEqual(stamp.timeIntervalSince(base), 0.5, accuracy: 0.001)
        XCTAssertNil(PipelineLogText.timestamp(of: "no timestamp here at all"))
    }

    func testSliceGivesEachStepItsOwnLinesAndContinuations() throws {
        func date(_ s: String) -> Date { PipelineParsing.date(s)! }
        let steps = [
            PipelineStep(name: "Checkout", state: .succeeded, startedAt: date("2026-10-02T10:00:01Z")),
            PipelineStep(name: "Test", state: .running, startedAt: date("2026-10-02T10:00:05Z")),
        ]
        let log = """
            2026-10-02T10:00:00.1000000Z Set up job
            2026-10-02T10:00:01.2000000Z ##[group]Run actions/checkout
            continuation of checkout
            2026-10-02T10:00:04.9000000Z checked out
            2026-10-02T10:00:05.1000000Z ##[group]Run swift test
            2026-10-02T10:00:09.0000000Z running
            """
        let checkout = PipelineLogText.slice(jobLog: log, steps: steps, index: 0)
        XCTAssertTrue(checkout.contains("Run actions/checkout"))
        XCTAssertTrue(checkout.contains("continuation of checkout"))
        XCTAssertTrue(checkout.contains("checked out"))
        XCTAssertFalse(checkout.contains("Set up job"))
        XCTAssertFalse(checkout.contains("swift test"))
        let test = PipelineLogText.slice(jobLog: log, steps: steps, index: 1)
        XCTAssertTrue(test.contains("swift test") && test.contains("running"))
        XCTAssertFalse(test.contains("checked out"))
        let unstarted = [PipelineStep(name: "Later", state: .pending)]
        XCTAssertEqual(PipelineLogText.slice(jobLog: log, steps: unstarted, index: 0), "")
    }

    /// The hand parser must agree with the ISO-8601 formatter on every
    /// shape a log line can carry (leap years, month ends, fractions).
    func testHandParsedTimestampsMatchTheFormatter() throws {
        let stamps = [
            "2026-10-02T10:00:01", "2024-02-29T23:59:59", "2000-01-01T00:00:00", "2099-12-31T12:30:45",
            "2026-03-01T00:00:00", "2100-03-01T01:02:03",
        ]
        for stamp in stamps {
            let parsed = try XCTUnwrap(PipelineLogText.timestamp(of: Substring(stamp + "Z text")), stamp)
            let reference = try XCTUnwrap(PipelineParsing.date(stamp + "Z"), stamp)
            XCTAssertEqual(parsed.timeIntervalSince1970, reference.timeIntervalSince1970, accuracy: 0.0001, stamp)
        }
        let fractional = try XCTUnwrap(PipelineLogText.timestamp(of: "2026-10-02T10:00:01.123456Zx"))
        let base = try XCTUnwrap(PipelineParsing.date("2026-10-02T10:00:01Z"))
        XCTAssertEqual(fractional.timeIntervalSince(base), 0.123456, accuracy: 0.0001)
        XCTAssertNil(PipelineLogText.timestamp(of: "2026-13-02T10:00:01Z too many months"))
        XCTAssertNil(PipelineLogText.timestamp(of: "2026-10-02 10:00:01Z not iso"))
        XCTAssertNil(PipelineLogText.timestamp(of: "2026-10-02T10:00:01+0200 offset"))
    }

    func testPipelineDateParsesFractionalSecondsAndTimeZones() throws {
        let plain = try XCTUnwrap(PipelineParsing.date("2026-10-02T10:00:01Z"))
        let fractional = try XCTUnwrap(PipelineParsing.date("2026-10-02T10:00:01.250Z"))
        XCTAssertEqual(fractional.timeIntervalSince(plain), 0.25, accuracy: 0.001)
        let offset = try XCTUnwrap(PipelineParsing.date("2026-10-02T12:00:01+02:00"))
        XCTAssertEqual(offset, plain)
        let fractionalOffset = try XCTUnwrap(PipelineParsing.date("2026-10-02T05:00:01.5-05:00"))
        XCTAssertEqual(fractionalOffset.timeIntervalSince(plain), 0.5, accuracy: 0.001)
        XCTAssertNil(PipelineParsing.date("yesterday"))
        XCTAssertNil(PipelineParsing.date(nil))
    }

    func testHugeRawLogIsTrimmedToItsTailAtLineBoundariesBeforeCleaning() {
        let raw = (1...5000).map { "\u{1B}[32mline \($0)\u{1B}[0m" }.joined(separator: "\n")
        let (text, truncated) = PipelineLogText.clean(raw, limit: 1_000_000, rawTailBytes: 4000)
        XCTAssertTrue(truncated, "head was dropped")
        XCTAssertTrue(text.hasSuffix("line 5000"))
        XCTAssertTrue(text.hasPrefix("line "), "whole first line: \(text.prefix(12))")
        XCTAssertFalse(text.contains("\u{1B}"))
        XCTAssertLessThan(text.utf8.count, 4000)
        // A log under the budget is untouched.
        let small = PipelineLogText.clean("a\nb\n", limit: 100, rawTailBytes: 4000)
        XCTAssertEqual(small.text, "a\nb\n")
        XCTAssertFalse(small.truncated)
    }
}
