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
        let snapshot = FleetEngine.queueSnapshot(
            [
                ("github", ForgeJob.fifoOrdered([job("g-new", at: 300), job("g-old", at: 100)])),
                ("gitea", [job("t-mid", at: 200, repo: "acme/web")]),
            ], runtime: { _ in .tart })
        XCTAssertEqual(snapshot.entries.map(\.name), ["g-old", "t-mid", "g-new"])
        XCTAssertEqual(snapshot.entries.map(\.position), [1, 2, 3])
        XCTAssertEqual(snapshot.entries.map(\.forge), ["github", "gitea", "github"])
        XCTAssertEqual(snapshot.byForge, ["github": 2, "gitea": 1])
        XCTAssertEqual(
            snapshot.datesByForge["github"]?[.tart],
            [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 300)])
    }

    func testAssignedScaleSetJobsAreDemandButNotWaiting() {
        let snapshot = FleetEngine.queueSnapshot(
            [("scale", [job("running", at: 1, assigned: true), job("waiting", at: 2)])], runtime: { _ in .tart })
        XCTAssertEqual(snapshot.entries.map(\.name), ["waiting"])
        XCTAssertEqual(snapshot.byForge, ["scale": 1])
    }

    func testTakenJobsLeadTheDatesSoTheOldestWaitingJobIsNextInLine() {
        // github has a waiting job at 10 and one a runner already took at 100; its busy VM covers the taken one.
        let snapshot = FleetEngine.queueSnapshot(
            [
                ("github", [job("waiting", at: 10), job("taken", at: 100, assigned: true)]),
                ("gitea", [job("other", at: 20)]),
            ], runtime: { _ in .tart })
        XCTAssertEqual(
            snapshot.datesByForge["github"]?[.tart],
            [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 10)])
        var plan = input(demand: ["github": [.tart: 2], "gitea": [.tart: 1]], dates: [:])
        plan.queueDatesByAccount = snapshot.datesByForge
        let totals = ["github": 2, "gitea": 1]
        let busy = vm("github", .tart, phase: .busy)  // a scale-set VM's job counts as demand, so it covers
        plan.includesRunning = ["github"]
        XCTAssertEqual(ScalePlan.account(for: .tart, totals: totals, records: [busy], input: plan), "github")
    }

    func testDatesAreKeptPerRuntime() {
        // github: a Tart job at 10 and an Apple container job at 100; gitea: an Apple container job at 20.
        let snapshot = FleetEngine.queueSnapshot(
            [
                ("github", [job("tart", at: 10), job("container", at: 100)]),
                ("gitea", [job("other", at: 20)]),
            ], runtime: { $0.name == "tart" ? .tart : .appleContainer })
        XCTAssertEqual(snapshot.datesByForge["github"]?[.tart], [Date(timeIntervalSince1970: 10)])
        XCTAssertEqual(snapshot.datesByForge["github"]?[.appleContainer], [Date(timeIntervalSince1970: 100)])
    }

    func testTheContainerSlotGoesToTheOldestContainerJobNotTheOldestJobOverall() {
        // github has Tart@10 and container@100, gitea has container@20: the container slot belongs to gitea.
        var plan = input(
            demand: ["github": [.tart: 1, .appleContainer: 1], "gitea": [.appleContainer: 1]], dates: [:])
        plan.queueDatesByAccount = [
            "github": [.tart: [Date(timeIntervalSince1970: 10)], .appleContainer: [Date(timeIntervalSince1970: 100)]],
            "gitea": [.appleContainer: [Date(timeIntervalSince1970: 20)]],
        ]
        let totals = ["github": 2, "gitea": 1]
        XCTAssertEqual(ScalePlan.account(for: .appleContainer, totals: totals, records: [], input: plan), "gitea")
        XCTAssertEqual(ScalePlan.account(for: .tart, totals: totals, records: [], input: plan), "github")
    }

    func testAnInstanceOnAnotherRuntimeDoesNotCoverTheJobsHere() {
        // github's Tart VM is already planned; its container job at 5 is still uncovered, so github wins the
        // container slot over gitea's job at 20.
        var plan = input(
            demand: ["github": [.tart: 1, .appleContainer: 1], "gitea": [.appleContainer: 1]], dates: [:])
        plan.queueDatesByAccount = [
            "github": [.tart: [Date(timeIntervalSince1970: 1)], .appleContainer: [Date(timeIntervalSince1970: 5)]],
            "gitea": [.appleContainer: [Date(timeIntervalSince1970: 20)]],
        ]
        let totals = ["github": 2, "gitea": 1]
        let tartVM = vm("github", .tart)
        XCTAssertEqual(
            ScalePlan.account(for: .appleContainer, totals: totals, records: [tartVM], input: plan), "github")
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

    private func vm(_ account: String, _ runtime: RuntimeID, phase: VMPhase = .ready) -> VMRecord {
        var record = VMRecord(id: "vm-\(account)-\(runtime.rawValue)", phase: phase)
        record.platform = account
        record.runtimeID = runtime
        return record
    }

    private func input(
        demand: [String: [RuntimeID: Int]], dates: [String: [TimeInterval]], rpv: Int = 1
    ) -> ScalePlan.Input {
        var input = ScalePlan.Input(
            records: [], demand: demand, attached: Set(demand.keys), runnersPerVM: rpv, maxRunners: 10,
            capacityCap: 10, existingPools: [.tart, .appleContainer], defaultRuntime: .tart)
        input.queueDatesByAccount = dates.mapValues { [.tart: $0.map { Date(timeIntervalSince1970: $0) }] }
        return input
    }

    func testAccountIsChosenAmongThoseQueuedOnTheChosenRuntime() {
        // github's older job needs Tart; gitea's two newer jobs need an Apple container. An instance on Apple
        // container must not be registered with github.
        let plan = input(
            demand: ["github": [.tart: 1], "gitea": [.appleContainer: 2]],
            dates: ["github": [10], "gitea": [20, 30]])
        let account = ScalePlan.account(
            for: .appleContainer, totals: ["github": 1, "gitea": 2], records: [], input: plan)
        XCTAssertEqual(account, "gitea")
        let tart = ScalePlan.account(for: .tart, totals: ["github": 1, "gitea": 2], records: [], input: plan)
        XCTAssertEqual(tart, "github")
    }

    func testAccountMatchesTheRuntimeEvenWithoutQueueDates() {
        // Two Tart jobs on github, two Apple container jobs on gitea, one slot: the runtime selector takes Apple
        // container on the tie, and the instance must go to gitea, not to github on the demand tie.
        let plan = input(demand: ["github": [.tart: 2], "gitea": [.appleContainer: 2]], dates: [:])
        let account = ScalePlan.account(
            for: .appleContainer, totals: ["github": 2, "gitea": 2], records: [], input: plan)
        XCTAssertEqual(account, "gitea")
    }

    func testRunningJobsReportedByTwoForgesCountOnce() {
        let job = RunningJob(name: "build", runnerName: "vm-1", repository: "acme/api")
        let other = RunningJob(name: "test", runnerName: "vm-2", repository: "acme/api")
        let unnamed = RunningJob(name: "x", runnerName: nil, repository: nil)
        let result = FleetEngine.deduplicated([job, other, job, unnamed, unnamed])
        XCTAssertEqual(result.map(\.name), ["build", "test", "x", "x"])
    }

    func testTheQueueHeadAdvancesAsPlannedInstancesCoverJobs() {
        // github jobs at 10 and 100, gitea jobs at 20 and 30: github's job at 10 first, then (github now covered
        // up to its second job, dated 100) gitea's job at 20.
        let plan = input(
            demand: ["github": [.tart: 2], "gitea": [.tart: 2]], dates: ["github": [10, 100], "gitea": [20, 30]])
        let totals = ["github": 2, "gitea": 2]
        XCTAssertEqual(ScalePlan.account(for: .tart, totals: totals, records: [], input: plan), "github")
        XCTAssertEqual(
            ScalePlan.account(for: .tart, totals: totals, records: [vm("github", .tart)], input: plan), "gitea")
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
