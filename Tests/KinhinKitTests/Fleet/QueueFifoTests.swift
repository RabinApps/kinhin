import XCTest

@testable import KinhinKit

/// Kinhin orders its own queue first in, first out by the date the forge created each job, and serves the account
/// whose head-of-queue job has waited longest first.
final class QueueFifoTests: XCTestCase {
    private func job(_ name: String, at seconds: TimeInterval?, repo: String = "acme/api", assigned: Bool = false)
        -> ForgeJob
    {
        ForgeJob(
            name: name, runnerName: nil, repository: repo,
            correlation: seconds.map { JobCorrelation(enqueuedAt: Date(timeIntervalSince1970: $0)) },
            isAssigned: assigned)
    }

    func testForgeJobsOrderOldestCreatedFirstUndatedLastStable() {
        let jobs = [
            job("c", at: 30), job("none-1", at: nil), job("a", at: 10), job("none-2", at: nil), job("b", at: 20),
        ]
        XCTAssertEqual(ForgeJob.fifoOrdered(jobs).map(\.name), ["a", "b", "c", "none-1", "none-2"])
    }

    func testEqualDatesKeepTheForgesOrder() {
        let jobs = [job("x", at: 5), job("y", at: 5), job("z", at: 5)]
        XCTAssertEqual(ForgeJob.fifoOrdered(jobs).map(\.name), ["x", "y", "z"])
    }

    func testQueueSnapshotMergesForgesOldestFirstWithPositions() {
        let snapshot = FleetEngine.queueSnapshot([
            ("github", ForgeJob.fifoOrdered([job("g-new", at: 300), job("g-old", at: 100)])),
            ("gitea", [job("t-mid", at: 200, repo: "acme/web")]),
        ])
        XCTAssertEqual(snapshot.entries.map(\.name), ["g-old", "t-mid", "g-new"])
        XCTAssertEqual(snapshot.entries.map(\.position), [1, 2, 3])
        XCTAssertEqual(snapshot.entries.map(\.forge), ["github", "gitea", "github"])
        XCTAssertEqual(snapshot.byForge, ["github": 2, "gitea": 1])
        XCTAssertEqual(snapshot.oldestByForge["github"], Date(timeIntervalSince1970: 100))
    }

    func testAssignedScaleSetJobsAreDemandButNotWaiting() {
        let snapshot = FleetEngine.queueSnapshot([
            ("scale", [job("running", at: 1, assigned: true), job("waiting", at: 2)])
        ])
        XCTAssertEqual(snapshot.entries.map(\.name), ["waiting"])
        XCTAssertEqual(snapshot.byForge, ["scale": 1])
    }

    func testOldestWaitingAccountIsServedFirstNotTheLargestQueue() {
        let account = ForgeDemand.assignAccount(
            demand: ["github": 5, "gitea": 1], active: [:], attached: ["github", "gitea"],
            oldest: ["github": Date(timeIntervalSince1970: 200), "gitea": Date(timeIntervalSince1970: 100)])
        XCTAssertEqual(account, "gitea")
    }

    func testWithoutDatesTheLargestUnmetDemandStillWins() {
        let account = ForgeDemand.assignAccount(
            demand: ["github": 1, "gitea": 4], active: [:], attached: ["github", "gitea"])
        XCTAssertEqual(account, "gitea")
    }

    func testAnAccountWithNoUnmetDemandIsSkippedEvenIfItsJobIsOld() {
        let account = ForgeDemand.assignAccount(
            demand: ["github": 1, "gitea": 1], active: ["gitea": 1], attached: ["github", "gitea"],
            oldest: ["gitea": Date(timeIntervalSince1970: 1), "github": Date(timeIntervalSince1970: 9)])
        XCTAssertEqual(account, "github")
    }

    func testReportSplitsRunningFromQueuedAndFlagsBusyVMsWithoutAJob() {
        var named = VMRecord(id: "vm-1", phase: .busy)
        named.platform = "github"
        named.runningJobs = [
            RunningJobStamp(
                runner: "vm-1", job: "build", repo: "acme/api", startedAt: Date(timeIntervalSince1970: 50))
        ]
        let silent = VMRecord(id: "vm-2", phase: .busy)
        var status = FleetStatus()
        status.records = [named, silent]
        status.queueDepth = 5
        status.queueByForge = ["github": 2]
        status.queuedJobs = FleetJobsReport.fifo([
            FleetJobsReport.Entry(name: "b", forge: "github", enqueuedAt: Date(timeIntervalSince1970: 2)),
            FleetJobsReport.Entry(name: "a", forge: "github", enqueuedAt: Date(timeIntervalSince1970: 1)),
        ])
        let report = FleetJobsReport(status: status)
        XCTAssertEqual(report.running.map(\.name), ["build"])
        XCTAssertEqual(report.running.first?.vm, "vm-1")
        XCTAssertEqual(report.running.first?.forge, "github")
        XCTAssertEqual(report.unattributedBusy, ["vm-2"])
        XCTAssertEqual(report.queued.map(\.name), ["a", "b"])
        XCTAssertEqual(report.queueDepth, 2, "waiting jobs only, not the scale-set demand total")
    }

    func testOlderDaemonStatusWithoutTheQueueListStillReportsTheDepth() throws {
        let status = try JSONDecoder().decode(
            FleetStatus.self, from: JSONEncoder().encode(FleetStatus(running: true, queueDepth: 3)))
        XCTAssertNil(status.queuedJobs)
        let report = FleetJobsReport(status: status)
        XCTAssertEqual(report.queueDepth, 3)
        XCTAssertTrue(report.queued.isEmpty)
    }

    func testScaleSetEventDecodesQueueTime() throws {
        let json = """
            {"messageType":"JobAvailable","ownerName":"acme","repositoryName":"api","jobDisplayName":"build",
             "requestLabels":["kinhin-container"],"runnerRequestId":7,"queueTime":"2026-11-21T10:00:00.5Z"}
            """
        let event = try JSONDecoder().decode(GitHubScaleSetJobEvent.self, from: Data(json.utf8))
        XCTAssertNotNil(event.queueTime)
        let without = try JSONDecoder().decode(
            GitHubScaleSetJobEvent.self,
            from: Data(
                #"{"messageType":"JobAvailable","ownerName":"a","repositoryName":"b","jobDisplayName":"c","runnerRequestId":"1"}"#
                    .utf8))
        XCTAssertNil(without.queueTime)
    }
}
