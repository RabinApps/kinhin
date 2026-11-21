import XCTest

@testable import KinhinKit
@testable import kinhin

/// `kinhin jobs` / `kinhin queue`: argument parsing, the text and the JSON document.
final class JobsCommandTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private var report: FleetJobsReport {
        FleetJobsReport(
            running: [
                .init(
                    name: "build", repo: "acme/api", forge: "github", vm: "kinhin-1", runner: "kinhin-1",
                    startedAt: now.addingTimeInterval(-192))
            ],
            queued: FleetJobsReport.fifo([
                .init(name: "test", repo: "acme/web", forge: "gitea", enqueuedAt: now.addingTimeInterval(-30)),
                .init(name: "lint", repo: "acme/api", forge: "github", enqueuedAt: now.addingTimeInterval(-300)),
            ]),
            queueDepth: 2, queueByForge: ["github": 1, "gitea": 1], polled: true)
    }

    // MARK: - Parsing

    func testParse() {
        XCTAssertEqual(JobsCommand.parse(["jobs"]), JobsCommand.Options())
        XCTAssertEqual(JobsCommand.parse(["jobs", "--queued"])?.view, .queued)
        XCTAssertEqual(JobsCommand.parse(["jobs", "--running", "--json"])?.view, .running)
        XCTAssertEqual(JobsCommand.parse(["jobs", "--forge", "github", "--watch"])?.forge, "github")
        XCTAssertEqual(JobsCommand.parse(["queue"], defaultView: .queued)?.view, .queued)
        XCTAssertNil(JobsCommand.parse(["jobs", "--forge"]), "a flag without its value is a usage error")
        XCTAssertNil(JobsCommand.parse(["jobs", "bogus"]))
        XCTAssertNil(JobsCommand.parse(["queue", "--running"], defaultView: .queued), "queue is queued-only")
    }

    func testRoutesBothWords() {
        XCTAssertEqual(CLICommand.parse(["jobs"]), .jobs)
        XCTAssertEqual(CLICommand.parse(["queue"]), .queue)
    }

    // MARK: - Text

    func testQueueListsOldestFirstWithForgeAndAge() {
        let text = JobsCommand.render(report, options: JobsCommand.Options(view: .queued), now: now)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "queued (2) · oldest first")
        XCTAssertTrue(lines[2].hasPrefix("  #1  lint"), lines[2])
        XCTAssertTrue(lines[2].contains("github") && lines[2].hasSuffix("5m00s"), lines[2])
        XCTAssertTrue(lines[3].hasPrefix("  #2  test") && lines[3].hasSuffix("30s"), lines[3])
    }

    func testJobsShowsRunningThenQueued() {
        let text = JobsCommand.render(report, options: JobsCommand.Options(), now: now)
        XCTAssertTrue(text.hasPrefix("running (1)"))
        XCTAssertTrue(text.contains("build") && text.contains("kinhin-1") && text.contains("3m12s"), text)
        XCTAssertTrue(text.contains("queued (2)"))
    }

    func testEmptySectionsSayNone() {
        let text = JobsCommand.render(FleetJobsReport(polled: true), options: JobsCommand.Options(), now: now)
        XCTAssertEqual(text, "running (0)\n  none\n\nqueued (0)\n  none")
    }

    func testBusyVMWithoutANamedJobStillAppears() {
        let text = JobsCommand.render(
            FleetJobsReport(unattributedBusy: ["kinhin-9"]), options: JobsCommand.Options(view: .running), now: now)
        XCTAssertTrue(text.contains("(job not named yet)") && text.contains("kinhin-9"), text)
    }

    func testAnOlderDaemonThatSendsNoListStillShowsTheCount() {
        let text = JobsCommand.render(
            FleetJobsReport(queueDepth: 4), options: JobsCommand.Options(view: .queued), now: now)
        XCTAssertTrue(text.contains("4 waiting; this daemon does not list them"), text)
    }

    func testAJobBeyondTheCapIsCounted() {
        var capped = report
        capped.queueDepth = 5
        let text = JobsCommand.render(capped, options: JobsCommand.Options(view: .queued), now: now)
        XCTAssertTrue(text.contains("… and 3 more"), text)
    }

    // MARK: - Filtering and JSON

    func testForgeFilterKeepsOneAccountAndRenumbers() {
        let github = JobsCommand.filtered(report, forge: "GitHub")
        XCTAssertEqual(github.queued.map(\.name), ["lint"])
        XCTAssertEqual(github.queued.first?.position, 1)
        XCTAssertEqual(github.running.map(\.name), ["build"])
        XCTAssertEqual(github.queueDepth, 1)
        XCTAssertTrue(JobsCommand.filtered(report, forge: "gitea").running.isEmpty)
    }

    func testViewLimitsTheJSONHalves() {
        let running = JobsCommand.limited(report, to: .running)
        XCTAssertEqual(running.running.count, 1)
        XCTAssertTrue(running.queued.isEmpty)
        XCTAssertEqual(running.queueDepth, 0)
        let queued = JobsCommand.limited(report, to: .queued)
        XCTAssertTrue(queued.running.isEmpty)
        XCTAssertEqual(queued.queued.count, 2)
        XCTAssertEqual(JobsCommand.limited(report, to: .all), report)
    }

    func testDurationFormats() {
        XCTAssertEqual(JobsCommand.duration(-5), "0s")
        XCTAssertEqual(JobsCommand.duration(59), "59s")
        XCTAssertEqual(JobsCommand.duration(125), "2m05s")
        XCTAssertEqual(JobsCommand.duration(7500), "2h05m")
    }

    func testJSONDocumentCarriesISODatesAndPositions() throws {
        let data = try CLIJSON.data(
            JobsCommand.Document(daemonRunning: true, jobs: report), dates: .iso8601)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"position\" : 1"), text)
        XCTAssertTrue(text.contains("1970-01-01T"), "dates are ISO-8601, not seconds since 2001")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(JobsCommand.Document.self, from: data).jobs, report)
        let none = try CLIJSON.string(JobsCommand.Document(daemonRunning: false, jobs: nil))
        XCTAssertTrue(none.contains("\"daemonRunning\" : false"))
    }
}
