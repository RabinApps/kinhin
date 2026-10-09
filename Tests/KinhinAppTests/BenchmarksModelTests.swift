import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class BenchmarksModelTests: XCTestCase {
    private var directory: URL!
    private var fake: FakeFleetServing!
    private var model: BenchmarksModel!
    private var asked: [(title: String, message: String)] = []
    private var presented: [Error] = []
    private var answer = true

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-bench-model-\(UUID().uuidString)", isDirectory: true)
        fake = FakeFleetServing(FleetStatus(running: true, records: []))
        model = BenchmarksModel()
        model.store = BenchmarkReportStore(directory: directory)
        model.pollInterval = .milliseconds(1)
        let service = fake!
        model.runner = { ServiceBenchmarkRunner(service: service) }
        model.confirm = { [unowned self] title, message, _ in
            asked.append((title, message))
            return answer
        }
        model.present = { [unowned self] in presented.append($0) }
    }

    private func waitUntil(
        _ message: String = "the condition holds", timeout: Duration = .seconds(5), _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out: \(message)") }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    override func tearDown() async throws {
        model.stopPolling()
        try? FileManager.default.removeItem(at: directory)
    }

    private func status(
        _ state: BenchmarkRunStatus.State, report: BenchmarkReport? = nil, completed: [BenchmarkSuiteResult] = [],
        error: String? = nil, phase: String = "running"
    ) -> BenchmarkRunStatus {
        BenchmarkRunStatus(
            runID: "bench-fake", state: state,
            progress: BenchmarkProgress(
                phase: phase, suite: "boot", runtime: "tart", step: "clone", completed: completed),
            startedAt: Date(), elapsedSeconds: 4, report: report, error: error)
    }

    private func sampleReport() -> BenchmarkReport {
        BenchmarkReport(
            runID: "bench-fake", startedAt: Date(), finishedAt: Date(), kinhinVersion: "0.0.1",
            host: .init(chip: "Apple M9", cores: 12, memoryGB: 64, freeDiskGB: 400, arm64: true, os: "macOS"),
            setup: .init(
                image: "tahoe-base", containerImage: nil, dockerImage: nil, runtimes: ["tart", "docker"], vmCPU: 4,
                vmMemoryGB: 8, softnet: false),
            intensity: "quick",
            suites: [
                BenchmarkSuiteResult(
                    name: "boot", runtime: "tart", platform: "macOS", status: .ran,
                    steps: [
                        BenchmarkStep(name: "clone", durationMs: 1200, minMs: 1000, maxMs: 1500, samples: 3),
                        BenchmarkStep(name: "boot-to-IP", durationMs: 14_000),
                    ]),
                BenchmarkSuiteResult(
                    name: "boot", runtime: "docker", platform: "linux/arm64", status: .ran,
                    steps: [BenchmarkStep(name: "start", durationMs: 800)]),
                BenchmarkSuiteResult(
                    name: "boot", runtime: "host", status: .skipped, skipReason: "needs --include-host"),
                BenchmarkSuiteResult(
                    name: "casual", runtime: "tart", platform: "macOS", status: .ran,
                    steps: [
                        BenchmarkStep(name: "tar-gzip", durationMs: 2500, throughput: 120_000_000),
                        BenchmarkStep(name: "swift-build", durationMs: 0, note: "no Swift toolchain", skipped: true),
                    ]),
                BenchmarkSuiteResult(
                    name: "toolchains", runtime: "tart", platform: "macOS", status: .ran,
                    toolchains: [
                        ToolchainBenchRow(
                            tool: "node", platform: "macOS", runtime: "tart", installer: "mise node@22", status: .ran,
                            installMs: 30_000, verifyMs: 200, workloadMs: 600, workload: "node script"),
                        ToolchainBenchRow(
                            tool: "go", platform: "macOS", runtime: "tart", installer: "mise go@latest", status: .ran,
                            installMs: 90_000, verifyMs: 100, workloadMs: 4000, workload: "go build"),
                        ToolchainBenchRow(
                            tool: "vault", platform: "macOS", runtime: "tart", installer: "mise vault@latest",
                            status: .ran, verifyMs: 90, skipReason: "talks to a Vault server"),
                    ]),
            ])
    }

    // MARK: - Choices

    func testDefaultsAreTheFourQuickSuitesWithoutToolchains() {
        XCTAssertEqual(model.selectedSuites, [.boot, .casual, .xcode, .large])
        XCTAssertEqual(model.intensity, .quick)
        XCTAssertTrue(model.canRun)
        let options = model.makeOptions()
        XCTAssertEqual(options.suites, [.boot, .casual, .xcode, .large])
        XCTAssertFalse(options.allToolchains)
        XCTAssertFalse(options.includeHost, "the unisolated host runtime is a CLI-consent feature")
    }

    func testNothingSelectedCannotRun() {
        model.selectedSuites = []
        XCTAssertFalse(model.canRun)
        model.runClicked()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(fake.benchStarted.isEmpty)
    }

    func testThoroughToolchainsCoverTheCatalogAndWarnAboutHours() {
        model.selectedSuites = [.toolchains]
        XCTAssertNil(model.toolchainsWarning, "a quick pass takes minutes")
        model.intensity = .thorough
        XCTAssertNotNil(model.toolchainsWarning)
        let options = model.makeOptions()
        XCTAssertEqual(options.suites, [.toolchains])
        XCTAssertTrue(options.allToolchains)
        XCTAssertNoThrow(try options.validate())
    }

    // MARK: - Run

    func testRunConfirmsStartsPollsAndShowsTheReport() async throws {
        let report = sampleReport()
        fake.benchStatuses = [
            status(.running), status(.running, completed: [report.suites[0]]), status(.finished, report: report),
        ]
        model.runClicked()
        XCTAssertEqual(model.phase, .starting)
        await waitUntil { self.model.phase != .starting }
        await model.waitForPoll()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(model.report?.runID, "bench-fake")
        XCTAssertEqual(fake.benchStarted.first?.confirmed, true, "the dialog is the confirmation the runner needs")
        XCTAssertEqual(fake.benchStarted.first?.suites, [.boot, .casual, .xcode, .large])
        XCTAssertEqual(model.status.style, .ok)
        XCTAssertTrue(presented.isEmpty)
    }

    func testTheConfirmationNamesTheFleetPause() async throws {
        fake.status = FleetStatus(
            running: true, records: [VMRecord(id: "kinhin-1", phase: .ready), VMRecord(id: "kinhin-2", phase: .busy)])
        fake.benchStatuses = [status(.finished, report: sampleReport())]
        model.runClicked()
        await waitUntil { !self.asked.isEmpty }
        XCTAssertTrue(asked[0].message.contains("2"), asked[0].message)
        XCTAssertTrue(asked[0].message.localizedCaseInsensitiveContains("paused"), asked[0].message)
        await model.waitForPoll()
    }

    func testDecliningTheConfirmationStartsNothing() async throws {
        answer = false
        model.runClicked()
        await waitUntil { !self.asked.isEmpty && self.model.phase == .idle }
        XCTAssertTrue(fake.benchStarted.isEmpty)
        XCTAssertNil(model.report)
    }

    func testAFailedRunShowsItsReasonAndAnAlert() async throws {
        fake.benchStatuses = [status(.failed, error: "image 'tahoe-base' is not on this Mac")]
        model.runClicked()
        await waitUntil { self.model.phase != .starting }
        await model.waitForPoll()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.status.text.contains("tahoe-base"))
        XCTAssertEqual(model.status.style, .error)
        XCTAssertEqual(presented.count, 1, "a failed action is never silent")
    }

    func testAStartFailureIsPresented() async throws {
        fake.commandError = RPCError.connectionFailed("daemon.sock")
        model.runClicked()
        await waitUntil { self.model.phase == .idle && !self.presented.isEmpty }
        XCTAssertEqual(model.status.style, .error)
    }

    func testCancelAsksTheBackendToStopTheRun() async throws {
        fake.benchStatuses = [status(.running)]
        model.runClicked()
        await waitUntil { if case .running = self.model.phase { return true } else { return false } }
        model.cancelClicked()
        await waitUntil { !self.fake.benchCancelled.isEmpty }
        XCTAssertEqual(fake.benchCancelled, ["bench-fake"])
        fake.benchStatuses = [status(.cancelled)]
        await model.waitForPoll()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.report)
    }

    func testLiveProgressAndPartialsShowWhileRunning() async throws {
        let report = sampleReport()
        fake.benchStatuses = [status(.running, completed: [report.suites[0]])]
        model.runClicked()
        await waitUntil { !self.model.partials.isEmpty }
        XCTAssertEqual(model.progressLine, "boot › tart › clone")
        XCTAssertEqual(model.visibleSuites.count, 1, "finished suites show while the run goes on")
        fake.benchStatuses = [status(.finished, report: report)]
        await model.waitForPoll()
    }

    func testOpeningTheSectionAttachesToARunStillGoing() async throws {
        fake.benchStatuses = [status(.running), status(.finished, report: sampleReport())]
        model.reload()
        await waitUntil("the attached run finishes") { self.model.report != nil }
        await model.waitForPoll()
        XCTAssertEqual(model.report?.runID, "bench-fake")
        XCTAssertTrue(asked.isEmpty, "attaching is not a new run")
        XCTAssertTrue(fake.benchStarted.isEmpty)
    }

    // MARK: - History

    func testHistoryListsStoredReportsAndShowsTheNewest() throws {
        let store = BenchmarkReportStore(directory: directory)
        var older = sampleReport()
        older.runID = "bench-old-0001"
        older.startedAt = Date(timeIntervalSinceNow: -7200)
        try store.write(older)
        try store.write(sampleReport())
        model.reload()
        XCTAssertEqual(model.history.count, 2)
        XCTAssertEqual(model.report?.runID, "bench-fake", "the newest report is on screen")

        model.show(model.history[1])
        XCTAssertEqual(model.report?.runID, "bench-old-0001")
        XCTAssertFalse(model.historyTitle(model.history[0]).isEmpty)
    }

    func testReloadReportsTheSummaryToTheFleetTab() throws {
        try BenchmarkReportStore(directory: directory).write(sampleReport())
        var summary: String?
        model.onSummaryChanged = { summary = $0 }
        model.reload()
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("Apple M9") == true, summary ?? "")
    }

    // MARK: - Results

    func testBootComparisonHasOneRowPerRuntimeAndAColumnPerPhase() throws {
        try BenchmarkReportStore(directory: directory).write(sampleReport())
        model.reload()
        let comparison = try XCTUnwrap(model.bootComparison)
        XCTAssertEqual(comparison.columns, ["clone", "boot-to-IP", "start"])
        XCTAssertEqual(comparison.rows.map(\.runtime), ["tart · macOS", "docker · linux/arm64", "host"])
        let tart = comparison.rows[0]
        XCTAssertEqual(tart.cells.count, 3)
        XCTAssertEqual(tart.cells[2], "—", "a phase the runtime does not have")
        XCTAssertNotNil(comparison.rows[2].note, "a skipped runtime says why")
        XCTAssertNil(tart.note)
    }

    func testStepLinesCarryThroughputAndSkippedSteps() throws {
        try BenchmarkReportStore(directory: directory).write(sampleReport())
        model.reload()
        let casual = try XCTUnwrap(model.stepSuites.first)
        XCTAssertEqual(model.title(of: casual), "Casual — tart (macOS)")
        let lines = model.lines(of: casual)
        XCTAssertEqual(lines.map(\.name), ["tar-gzip", "swift-build"])
        XCTAssertTrue(lines[0].detail?.contains("/") == true, "throughput reads as a rate: \(lines[0].detail ?? "")")
        XCTAssertTrue(lines[1].skipped)
        XCTAssertEqual(lines[1].detail, "no Swift toolchain")
    }

    func testToolchainsTableSortsByTheChosenColumn() throws {
        try BenchmarkReportStore(directory: directory).write(sampleReport())
        model.reload()
        let suite = try XCTUnwrap(model.toolchainSuites.first)
        XCTAssertEqual(model.toolchainRows(of: suite).map(\.tool), ["go", "node", "vault"], "alphabetical by default")

        model.sortToolchains(by: .install)
        XCTAssertEqual(
            model.toolchainRows(of: suite).map(\.tool), ["node", "go", "vault"], "fastest install first; none last")
        model.sortToolchains(by: .install)
        XCTAssertEqual(model.toolchainRows(of: suite).map(\.tool).first, "vault", "descending flips it")

        model.sortToolchains(by: .workload)
        XCTAssertEqual(model.toolchainRows(of: suite).map(\.tool), ["node", "go", "vault"])
        let vault = try XCTUnwrap(model.toolchainRows(of: suite).first { $0.tool == "vault" })
        XCTAssertEqual(vault.note, "talks to a Vault server", "verify-only rows say why inline")
        XCTAssertEqual(vault.install, "—")
    }

    func testDurationsUseTheSystemFormatterAtTheRightScale() {
        let milliseconds = BenchmarksModel.milliseconds(812)
        let seconds = BenchmarksModel.milliseconds(12_400)
        let minutes = BenchmarksModel.milliseconds(180_000)
        XCTAssertTrue(milliseconds.contains("812"), milliseconds)
        XCTAssertTrue(seconds.contains("12"), seconds)
        XCTAssertTrue(minutes.contains("3"), minutes)
        XCTAssertNotEqual(milliseconds, seconds)
    }
}
