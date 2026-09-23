import XCTest
import KinhinKit
@testable import kinhin

final class RenderStatusTests: XCTestCase {
    // MARK: engine line

    func testStoppedEngine() {
        let text = renderStatus(FleetStatus())
        XCTAssertTrue(text.hasPrefix("engine:    stopped"), text)
    }

    func testRunningAndPausedEngineLines() {
        var status = FleetStatus()
        status.running = true
        XCTAssertTrue(renderStatus(status).contains("engine:    running"))

        status.paused = true
        XCTAssertTrue(renderStatus(status).contains("engine:    paused"))
    }

    // MARK: counters

    func testCountersAndJobSlotsLine() {
        var status = FleetStatus()
        status.running = true
        status.queueDepth = 4
        status.desired = 2
        status.capacityCap = 3
        status.jobCapacity = 6
        let text = renderStatus(status)
        XCTAssertTrue(text.contains("queue: 4   desired: 2   capacity cap: 3"), text)
        XCTAssertTrue(text.contains("job slots: 6 concurrent jobs (VM cap × runners_per_vm)"), text)
    }

    func testQueueByRepoShownWhenDepthPositive() {
        var status = FleetStatus()
        status.queueDepth = 3
        status.queueByRepo = ["alpha/one": 2, "beta/two": 1]
        let text = renderStatus(status)
        XCTAssertTrue(text.contains("queue by repo: alpha/one ×2, beta/two ×1"), text)
    }

    func testQueueByRepoSuppressedWhenQueueEmpty() {
        var status = FleetStatus()
        status.queueDepth = 0
        status.queueByRepo = ["alpha/one": 0]
        XCTAssertFalse(renderStatus(status).contains("queue by repo"), "stale per-repo rows must not render for an empty queue")
    }

    func testRunningByRepoShownWhenJobsActive() {
        var status = FleetStatus()
        status.running = true
        status.records = [makeRecord(phase: .busy)]
        status.runningByRepo = ["alpha/one": 1]
        let text = renderStatus(status)
        XCTAssertTrue(text.contains("running by repo: alpha/one ×1"), text)
    }

    // MARK: last error

    func testLastErrorLine() {
        var status = FleetStatus()
        status.lastError = "github unreachable"
        XCTAssertTrue(renderStatus(status).contains("last error: github unreachable"))
    }

    // MARK: VM listing

    func testNoVMsLine() {
        XCTAssertTrue(renderStatus(FleetStatus()).contains("no VMs"))
    }

    func testVMLineCarriesPhasePlatformIPOriginAndUptime() {
        var record = makeRecord(phase: .busy)
        record.job = "build-and-test"
        record.repos = ["alpha/one", "beta/two"]
        record.platform = "gitea"
        record.ip = "192.168.64.7"

        let text = renderStatus(FleetStatus(records: [record]))
        let line = try! XCTUnwrap(text.components(separatedBy: "\n").first { $0.contains(record.id) })

        XCTAssertTrue(line.contains("busy"), line)
        XCTAssertTrue(line.contains("[gitea]"), "non-github platform should render in brackets: \(line)")
        XCTAssertTrue(line.contains("ip=192.168.64.7"), line)
        XCTAssertTrue(line.contains("job=build-and-test"), line)
        XCTAssertTrue(line.contains("repos=alpha/one,beta/two"), line)
        XCTAssertTrue(line.contains("up="), "uptime should always render: \(line)")
    }

    func testGithubPlatformOmitsBracket() {
        var record = makeRecord(phase: .ready)
        record.platform = "github"
        let text = renderStatus(FleetStatus(records: [record]))
        let line = try! XCTUnwrap(text.components(separatedBy: "\n").first { $0.contains(record.id) })
        XCTAssertFalse(line.contains("["), "github is the default forge and should not be bracketed: \(line)")
    }

    func testVMErrorTruncatedTo120Chars() {
        var record = makeRecord(phase: .failed)
        record.error = String(repeating: "x", count: 300)
        let text = renderStatus(FleetStatus(records: [record]))
        let line = try! XCTUnwrap(text.components(separatedBy: "\n").first { $0.contains(record.id) })
        XCTAssertTrue(line.contains("error="), line)
        XCTAssertLessThanOrEqual(line.count, 300, "error should be prefix(120), not the full 300-char blob")
        XCTAssertFalse(line.contains(String(repeating: "x", count: 200)), "error blob should be truncated")
    }

    func testDeletingAndFailedVMsRender() {
        let deleting = makeRecord(phase: .deleting)
        var failed = makeRecord(phase: .failed)
        failed.error = "boot timeout"
        let text = renderStatus(FleetStatus(records: [deleting, failed]))
        XCTAssertTrue(text.contains("deleting"))
        XCTAssertTrue(text.contains("failed"))
        XCTAssertTrue(text.contains("error=boot timeout"))
    }

    // MARK: helpers

    private func makeRecord(phase: VMPhase) -> VMRecord {
        var record = VMRecord(id: "kinhin-\(phase.rawValue)-test", phase: phase)
        record.createdAt = Date()
        return record
    }
}
