import KinhinKit
import XCTest

@testable import kinhin

final class BenchCommandTests: XCTestCase {
    // MARK: - Routing

    func testBenchRoutesAndResolvesItsFlags() throws {
        XCTAssertEqual(CLICommand.parse(["bench"]), .bench)
        let invocation = try CommandResolver.resolve([
            "bench", "boot", "toolchains", "--thorough", "--toolchains", "node,go", "--runtime", "tart,docker",
            "--json",
        ])
        XCTAssertEqual(invocation.command, .bench)
        XCTAssertTrue(invocation.json)
        XCTAssertThrowsError(try CommandResolver.resolve(["bench", "--bogus"])) { error in
            XCTAssertEqual((error as? CLIError)?.exit, .usage)
        }
        XCTAssertThrowsError(try CommandResolver.resolve(["bench", "--iterations"]), "a value flag needs its value")
    }

    func testBenchCreatesTheStarterConfigLikeOtherRunningCommands() {
        XCTAssertTrue(CLICommand.shouldAutoCreateConfig(.bench))
    }

    // MARK: - Parsing

    func testBareBenchRunsEveryQuickSuiteButToolchains() throws {
        let request = try BenchCommand.parse([])
        XCTAssertEqual(request.options.suites, [.boot, .casual, .xcode, .large])
        XCTAssertEqual(request.options.intensity, .quick)
        XCTAssertNil(request.options.runtimes)
        XCTAssertFalse(request.json)
        XCTAssertFalse(request.yes)
    }

    func testNamedSuitesRunInCanonicalOrderWithoutDuplicates() throws {
        let request = try BenchCommand.parse(["large", "boot", "boot"])
        XCTAssertEqual(request.options.suites, [.boot, .large])
    }

    func testToolchainScopingImpliesTheToolchainsSuite() throws {
        XCTAssertEqual(try BenchCommand.parse(["--toolchains", "node"]).options.suites, [.toolchains])
        XCTAssertEqual(try BenchCommand.parse(["--all-toolchains"]).options.suites, [.toolchains])
        XCTAssertEqual(try BenchCommand.parse(["boot", "--toolchains", "node"]).options.suites, [.boot, .toolchains])
        let scoped = try BenchCommand.parse(["--toolchains", "node, go,,jq"]).options
        XCTAssertEqual(scoped.toolchains, ["node", "go", "jq"])
    }

    func testFlagsFillTheOptions() throws {
        let request = try BenchCommand.parse([
            "--thorough", "--iterations", "5", "--runtime", "tart,container", "--include-host", "--network",
            "https://example.com/x.git", "--project", "/tmp/app", "--keep", "--force", "--yes", "--json",
        ])
        let options = request.options
        XCTAssertEqual(options.intensity, .thorough)
        XCTAssertEqual(options.iterations, 5)
        XCTAssertEqual(options.runtimes, [.tart, .appleContainer])
        XCTAssertTrue(options.includeHost)
        XCTAssertEqual(options.networkURL, "https://example.com/x.git")
        XCTAssertEqual(options.projectPath, "/tmp/app")
        XCTAssertTrue(options.keep && options.force)
        XCTAssertTrue(request.yes && request.json)
        XCTAssertFalse(options.confirmed, "only the interactive confirmation or the daemon path sets this")
    }

    func testRuntimeAllMeansEveryHealthyRuntime() throws {
        XCTAssertNil(try BenchCommand.parse(["--runtime", "all"]).options.runtimes)
        XCTAssertEqual(BenchCommand.runtime(named: "container"), .appleContainer)
        XCTAssertEqual(BenchCommand.runtime(named: "host"), .host)
        XCTAssertNil(BenchCommand.runtime(named: "podman"))
    }

    func testBadValuesAreUsageErrors() {
        func usage(_ args: [String], file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try BenchCommand.parse(args), file: file, line: line) { error in
                XCTAssertEqual((error as? CLIError)?.exit, .usage, "\(args)", file: file, line: line)
            }
        }
        usage(["bogus"])
        usage(["--quick", "--thorough"])
        usage(["--iterations", "many"])
        usage(["--runtime", "podman"])
    }

    func testSemanticProblemsAreBenchmarkErrorsExitingRuntime() throws {
        for args in [
            ["--iterations", "99"], ["--network", "ext::sh"], ["--runtime", "host"], ["--toolchains", "nodejs"],
            ["toolchains", "--thorough"],
        ] {
            let options = try BenchCommand.parse(args).options
            XCTAssertThrowsError(try options.validate(), "\(args)") { error in
                XCTAssertEqual(CLIExit(error), .runtime, "\(args)")
            }
        }
    }

    // MARK: - Output

    private func report() -> BenchmarkReport {
        BenchmarkReport(
            runID: "bench-1", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_800_000_090), kinhinVersion: "0.0.1",
            host: .init(chip: "Apple M9", cores: 12, memoryGB: 64, freeDiskGB: 400, arm64: true, os: "macOS"),
            setup: .init(
                image: "tahoe-base", containerImage: nil, dockerImage: nil, runtimes: ["tart"], vmCPU: 4,
                vmMemoryGB: 8, softnet: false),
            intensity: "quick",
            suites: [
                BenchmarkSuiteResult(
                    name: "boot", runtime: "tart", platform: "macOS", status: .ran,
                    steps: [BenchmarkStep(name: "clone", durationMs: 1000, minMs: 900, maxMs: 1100, samples: 3)]),
                BenchmarkSuiteResult(
                    name: "boot", runtime: "host", status: .skipped, skipReason: "needs --include-host"),
            ])
    }

    func testJSONOutputIsExactlyTheReportDocument() throws {
        let text = BenchCommand.output(for: report(), json: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BenchmarkReport.self, from: Data(text.utf8))
        XCTAssertEqual(decoded.runID, "bench-1")
        XCTAssertEqual(decoded.suites.count, 2)
        XCTAssertTrue(text.hasPrefix("{"), "stdout carries the one document and nothing else")
        XCTAssertTrue(text.contains("\"2027-"), "dates are ISO-8601")
    }

    func testTextOutputNamesEachSuiteAndSkipReason() {
        let text = BenchCommand.output(for: report(), json: false)
        XCTAssertTrue(text.contains("boot › tart (macOS)"))
        XCTAssertTrue(text.contains("clone"))
        XCTAssertTrue(text.contains("min 900 ms, max 1.1 s, n=3"))
        XCTAssertTrue(text.contains("skipped: needs --include-host"))
    }

    // MARK: - Through a daemon

    private final class FakeDaemon: FleetServing, @unchecked Sendable {
        var active = 0
        var runStates: [BenchmarkRunStatus.State] = [.running, .finished]
        var report: BenchmarkReport?
        var startedWith: BenchmarkOptions?
        var cancelled: [String?] = []
        var failure: String?

        func status() async throws -> FleetStatus {
            FleetStatus(
                running: true,
                records: (0..<active).map { VMRecord(id: "kinhin-\($0)", phase: .ready) })
        }
        func start() async throws {}
        func stop() async throws {}
        func setPaused(_ paused: Bool) async throws {}
        func deleteVM(id: String) async throws {}
        func pipelineDetail(vmID: String) async throws -> PipelineDetail? { nil }
        func pipelineLog(vmID: String, jobID: String, stepIndex: Int?) async throws -> PipelineLog? { nil }
        func rotate(_ target: CredentialRotation.Target, token: String) async throws {}
        func requeueQueuedJobs(for forge: ForgeID) async throws {}
        func skipQueuedJobs(for forge: ForgeID) async throws {}
        var logName: String { "fake daemon" }

        func benchStart(_ options: BenchmarkOptions) async throws -> String {
            startedWith = options
            return "bench-1"
        }
        func benchStatus(runID: String?) async throws -> BenchmarkRunStatus {
            let state = runStates.isEmpty ? .finished : runStates.removeFirst()
            return BenchmarkRunStatus(
                runID: "bench-1", state: state, progress: BenchmarkProgress(phase: "running", suite: "boot"),
                startedAt: Date(), elapsedSeconds: 1, report: state == .finished ? report : nil, error: failure)
        }
        func benchCancel(runID: String?) async throws -> Bool {
            cancelled.append(runID)
            return true
        }
    }

    private func throughDaemon(
        _ daemon: FakeDaemon, args: [String] = [], interactive: Bool = false, answer: Bool = true
    ) async throws -> (BenchmarkReport, [String]) {
        let request = try BenchCommand.parse(args)
        let lines = LockedLines()
        let report = try await BenchCommand.runThroughDaemon(
            request, backend: daemon, interactive: interactive, confirm: { _ in answer },
            progress: { lines.append($0) }, poll: .milliseconds(1))
        return (report, lines.values)
    }

    func testTheDaemonPathStartsPollsAndReturnsTheReport() async throws {
        let daemon = FakeDaemon()
        daemon.report = report()
        let (result, lines) = try await throughDaemon(daemon, args: ["boot", "--json"])
        XCTAssertEqual(result.runID, "bench-1")
        XCTAssertEqual(daemon.startedWith?.suites, [.boot])
        XCTAssertTrue(daemon.startedWith?.confirmed == true, "the daemon is told the pause was agreed to")
        XCTAssertTrue(lines.contains { $0.contains("bench-1") })
        XCTAssertTrue(lines.contains("boot"))
    }

    func testALiveFleetNeedsYesWhenNotInteractive() async {
        let daemon = FakeDaemon()
        daemon.active = 3
        do {
            _ = try await throughDaemon(daemon)
            XCTFail("expected a usage error")
        } catch let error as CLIError {
            XCTAssertEqual(error.exit, .usage)
            XCTAssertTrue(error.message.contains("--yes"))
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertNil(daemon.startedWith, "nothing starts without agreement")
    }

    func testYesAgreesWithoutAPrompt() async throws {
        let daemon = FakeDaemon()
        daemon.active = 3
        daemon.report = report()
        _ = try await throughDaemon(daemon, args: ["--yes"])
        XCTAssertNotNil(daemon.startedWith)
    }

    func testAnInteractiveRunAsksAndHonoursNo() async throws {
        let declined = FakeDaemon()
        declined.active = 1
        do {
            _ = try await throughDaemon(declined, interactive: true, answer: false)
            XCTFail("expected the run to stop")
        } catch let error as CLIError {
            XCTAssertTrue(error.message.contains("left running"))
        }
        XCTAssertNil(declined.startedWith)

        let agreed = FakeDaemon()
        agreed.active = 1
        agreed.report = report()
        _ = try await throughDaemon(agreed, interactive: true, answer: true)
        XCTAssertNotNil(agreed.startedWith)
    }

    func testAFailedRunSurfacesTheDaemonsReason() async {
        let daemon = FakeDaemon()
        daemon.runStates = [.failed]
        daemon.failure = "image 'tahoe-base' is not on this Mac"
        do {
            _ = try await throughDaemon(daemon)
            XCTFail("expected an error")
        } catch let error as BenchmarkError {
            XCTAssertTrue(error.localizedDescription.contains("tahoe-base"))
            XCTAssertEqual(CLIExit(error), .runtime)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testCtrlCCancelsTheRunInTheDaemon() async throws {
        let daemon = FakeDaemon()
        daemon.runStates = Array(repeating: .running, count: 10_000)
        let request = try BenchCommand.parse([])
        let task = Task {
            try await BenchCommand.runThroughDaemon(
                request, backend: daemon, interactive: false, confirm: { _ in true }, progress: { _ in },
                poll: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(daemon.cancelled, ["bench-1"])
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }
    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
