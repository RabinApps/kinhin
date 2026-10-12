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

    func testOriginInTheFutureKeepsTheFleetIdleUntilItArrives() async throws {
        let clock = Mutex(now)
        let demo = DemoFleetServing(origin: now.addingTimeInterval(10), clock: { clock.withLock { $0 } })
        let before = try await demo.status()
        XCTAssertTrue(before.running)
        XCTAssertTrue(before.records.isEmpty)
        clock.withLock { $0 = now.addingTimeInterval(10 + 8) }
        let after = try await demo.status()
        XCTAssertGreaterThan(after.activeCount, 0)
    }

    func testEnvironmentOriginFixesWhenTheScriptStarts() async throws {
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        let demo = try XCTUnwrap(
            DemoFleetServing.fromEnvironment(["KINHIN_DEMO": "launch", "KINHIN_DEMO_ORIGIN": String(future)]))
        let status = try await demo.status()
        XCTAssertTrue(status.records.isEmpty)
    }

    // MARK: - Scripts as data

    func testScriptRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(timeline)
        XCTAssertEqual(try JSONDecoder().decode(DemoTimeline.self, from: data), timeline)
    }

    func testFailsIsOptionalInAScript() throws {
        let json = """
            {"period": 30, "capacity": 2, "jobs": [
              {"repo": "acme/api", "account": "github", "runtime": "docker", "workflow": "CI",
               "arrive": 1, "start": 2, "run": 5}]}
            """
        let script = try JSONDecoder().decode(DemoTimeline.self, from: Data(json.utf8)).validated()
        XCTAssertFalse(script.jobs[0].fails)
    }

    func testValidationExplainsWhatIsWrong() {
        func job(arrive: Double = 1, start: Double = 2, run: Double = 5, account: String = "github")
            -> DemoTimeline.Job
        {
            DemoTimeline.Job(
                repo: "a/b", account: account, runtime: .docker, workflow: "CI", arrive: arrive, start: start, run: run)
        }
        func script(period: Double = 30, capacity: Int = 2, _ jobs: [DemoTimeline.Job]) -> DemoTimeline {
            DemoTimeline(period: period, capacity: capacity, jobs: jobs)
        }
        func invalid(_ timeline: DemoTimeline) -> String? {
            do { _ = try timeline.validated(); return nil } catch { return "\(error)" }
        }
        XCTAssertNotNil(invalid(script(period: 0, [job()])))
        XCTAssertNotNil(invalid(script(capacity: 0, [job()])))
        XCTAssertNotNil(invalid(script([])))
        XCTAssertTrue(invalid(script([job(arrive: 5, start: 2)]))?.contains("start must be") == true)
        XCTAssertTrue(invalid(script([job(account: "notaforge")]))?.contains("not a forge") == true)
        XCTAssertTrue(invalid(script(period: 8, [job()]))?.contains("after the") == true)
        XCTAssertNil(invalid(script([job()])))
    }

    func testBuiltInLaunchScriptIsValid() throws {
        _ = try DemoTimeline.launch.validated()
        XCTAssertEqual(try DemoTimeline.load("launch"), DemoTimeline.launch)
        XCTAssertThrowsError(try DemoTimeline.load("nope"))
    }

    func testEnvironmentLoadsABuiltInNameOrAJSONFile() throws {
        XCTAssertNil(DemoFleetServing.fromEnvironment([:]))
        XCTAssertNotNil(DemoFleetServing.fromEnvironment(["KINHIN_DEMO": "launch"]))
        XCTAssertNil(DemoFleetServing.fromEnvironment(["KINHIN_DEMO": "nope"]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(timeline).write(to: url)
        XCTAssertNotNil(DemoFleetServing.fromEnvironment(["KINHIN_DEMO": url.path]))
    }

    /// The script the docs tell contributors to copy must stay playable.
    func testShippedExampleScriptIsValid() throws {
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("video/adapters/kinhin/demos/example.json")
        let script = try DemoTimeline.load(example.path)
        XCTAssertFalse(script.jobs.isEmpty)
        XCTAssertTrue(script.jobs.contains { $0.fails }, "the example shows how a failure is written")
    }
}
