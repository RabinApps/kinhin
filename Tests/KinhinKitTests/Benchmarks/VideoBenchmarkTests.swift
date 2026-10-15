import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class VideoBenchmarkTests: XCTestCase {
    private var harness: BenchHarness!

    override func setUp() {
        super.setUp()
        harness = BenchHarness()
    }

    override func tearDown() {
        harness.cleanUp()
        super.tearDown()
    }

    private final class ScriptedShell: ShellRunning, Sendable {
        let respond: @Sendable ([String]) -> Int32
        init(_ respond: @escaping @Sendable ([String]) -> Int32) { self.respond = respond }

        func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
            ShellResult(exitCode: respond(argv), stdout: "", stderr: "")
        }
    }

    private final class ScriptedProcess: VideoProcessRunning, Sendable {
        let calls = Locked<[[String]]>([])
        let exitCode: Int32
        init(exitCode: Int32 = 0) { self.exitCode = exitCode }

        func runInteractive(_ argv: [String]) async throws -> Int32 {
            calls.withLock { $0.append(argv) }
            return exitCode
        }
    }

    private func run(
        _ options: BenchmarkOptions, process: ScriptedProcess,
        installed: Set<VideoRuntime> = [.appleContainer, .docker], fleet: BenchmarkFleetControlling? = nil
    ) async throws -> BenchmarkReport {
        var env = harness.makeEnvironment(fleet: fleet)
        env.drainPoll = .milliseconds(1)
        env.videoRunner = {
            VideoRunner(
                shell: ScriptedShell { _ in 0 }, process: process, environment: [:], cpuCount: 8,
                binaries: { installed.contains($0) ? "/bin/\($0.rawValue)" : nil })
        }
        return try await BenchmarkRunner(environment: env).run(options)
    }

    func testAQuickRunTimesACleanAndACachedFastBuild() async throws {
        let process = ScriptedProcess()
        let report = try await run(BenchmarkOptions(suites: [.video]), process: process)
        let video = try XCTUnwrap(report.suite("video", runtime: .appleContainer))
        XCTAssertEqual(video.status, .ran, video.error ?? "")
        XCTAssertEqual(video.steps.map(\.name), ["clean-build", "cached-build"])
        let calls = process.calls.withLock { $0 }
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.contains("--fast") && $0.contains("bench") })
    }

    func testAThoroughRunAddsAFullQualityBuild() async throws {
        let process = ScriptedProcess()
        let report = try await run(BenchmarkOptions(suites: [.video], intensity: .thorough), process: process)
        let video = try XCTUnwrap(report.suite("video", runtime: .appleContainer))
        XCTAssertEqual(video.steps.map(\.name), ["clean-build", "cached-build", "full-build"])
        let last = try XCTUnwrap(process.calls.withLock { $0.last })
        XCTAssertFalse(last.contains("--fast"))
    }

    func testNoVideoRuntimeIsASkipNotAFailure() async throws {
        let process = ScriptedProcess()
        let report = try await run(BenchmarkOptions(suites: [.video]), process: process, installed: [])
        let video = try XCTUnwrap(report.suite("video", runtime: .appleContainer))
        XCTAssertEqual(video.status, .skipped)
        XCTAssertNotNil(video.skipReason)
        XCTAssertTrue(process.calls.withLock { $0.isEmpty })
    }

    func testAFailedBuildFailsTheSuite() async throws {
        let report = try await run(BenchmarkOptions(suites: [.video]), process: ScriptedProcess(exitCode: 3))
        let video = try XCTUnwrap(report.suite("video", runtime: .appleContainer))
        XCTAssertEqual(video.status, .failed)
        XCTAssertTrue(video.steps.isEmpty)
    }

    func testAVideoOnlyRunLeavesTheFleetAlone() async throws {
        let fleet = RecordingFleet(active: 2, busy: 1)
        // No `confirmed`: a run that paused the fleet would have been refused for its live VMs.
        let report = try await run(BenchmarkOptions(suites: [.video]), process: ScriptedProcess(), fleet: fleet)
        XCTAssertEqual(report.suite("video", runtime: .appleContainer)?.status, .ran)
        XCTAssertTrue(fleet.pauses.isEmpty)
    }

    func testTheBenchmarkProjectIsGeneratedInScratchAndRemoved() async throws {
        let process = ScriptedProcess()
        _ = try await run(BenchmarkOptions(suites: [.video]), process: process)
        let call = try XCTUnwrap(process.calls.withLock { $0.first })
        let mount = try XCTUnwrap(call.first { $0.hasSuffix(":/project:ro") })
        XCTAssertTrue(mount.contains("video-repo"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: String(mount.dropLast(":/project:ro".count))))
    }

    func testVideoIsOptInAndParsesAsASuiteWord() {
        XCTAssertFalse(BenchmarkOptions.Suite.defaults.contains(.video))
        XCTAssertEqual(BenchmarkOptions.Suite(rawValue: "video"), .video)
    }
}
