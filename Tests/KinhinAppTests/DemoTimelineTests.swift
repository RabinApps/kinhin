import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin_app

final class DemoTimelineTests: XCTestCase {
    private let timeline = DemoTimeline.launch
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func frames(_ body: (Double, FleetStatus) -> Void) {
        for tenth in 0..<Int(timeline.period * 10) {
            let t = Double(tenth) / 10
            body(t, timeline.status(elapsed: t, now: now))
        }
    }

    func testFramesAreDeterministicAndLoop() {
        let frame = timeline.status(elapsed: 12.3, now: now)
        XCTAssertEqual(frame, timeline.status(elapsed: 12.3, now: now))
        XCTAssertEqual(frame, timeline.status(elapsed: 12.3 + timeline.period, now: now))
    }

    func testStartsIdleAndDrainsBackToIdle() {
        for t in [0.5, timeline.period - 0.5] {
            let status = timeline.status(elapsed: t, now: now)
            XCTAssertTrue(status.records.isEmpty, "t=\(t)")
            XCTAssertEqual(status.queueDepth, 0, "t=\(t)")
        }
    }

    func testNeverExceedsCapacity() {
        frames { t, status in XCTAssertLessThanOrEqual(status.activeCount, timeline.capacity, "t=\(t)") }
    }

    func testShowsQueueScalingAndAFailure() {
        var sawQueue = false
        var sawBusy = false
        var sawFailed = false
        frames { _, status in
            sawQueue = sawQueue || status.queueDepth > 0
            sawBusy = sawBusy || status.records.contains { $0.phase == .busy }
            if status.records.contains(where: { $0.phase == .failed }) {
                sawFailed = true
                XCTAssertNotNil(status.lastError)
            }
        }
        XCTAssertTrue(sawQueue && sawBusy && sawFailed)
    }

    func testPipelineExistsOnlyForABusyInstance() throws {
        let t = 8.0
        let busy = try XCTUnwrap(timeline.status(elapsed: t, now: now).records.first { $0.phase == .busy })
        let detail = try XCTUnwrap(timeline.pipeline(vmID: busy.id, elapsed: t, now: now))
        XCTAssertEqual(detail.jobs.first?.isCurrent, true)
        XCTAssertNil(timeline.pipeline(vmID: "kinhin-unknown", elapsed: t, now: now))
    }

    func testServingFollowsItsClockAndStops() async throws {
        let clock = Mutex(now)
        let demo = DemoFleetServing(clock: { clock.withLock { $0 } })
        let initial = try await demo.status()
        XCTAssertTrue(initial.running)
        clock.withLock { $0 = now.addingTimeInterval(8) }
        let later = try await demo.status()
        XCTAssertGreaterThan(later.activeCount, 0)
        try await demo.stop()
        let stopped = try await demo.status()
        XCTAssertFalse(stopped.running)
        XCTAssertTrue(stopped.records.isEmpty)
    }
}
