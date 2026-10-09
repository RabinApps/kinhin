import XCTest

@testable import KinhinKit

final class BenchmarkReportTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-bench-reports-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeReport(runID: String = "bench-20261008-101010-abcd", started: Date = Date()) -> BenchmarkReport {
        BenchmarkReport(
            runID: runID, startedAt: started, finishedAt: started.addingTimeInterval(90), kinhinVersion: "9.9.9",
            host: .init(chip: "Apple M9", cores: 12, memoryGB: 64, freeDiskGB: 400, arm64: true, os: "macOS 27"),
            setup: .init(
                image: "tahoe-base", containerImage: "kinhin-ci-linux", dockerImage: nil, runtimes: ["tart", "docker"],
                vmCPU: 4, vmMemoryGB: 8, softnet: true),
            intensity: "thorough",
            suites: [
                BenchmarkSuiteResult(
                    name: "boot", runtime: "tart", platform: "macOS", status: .ran,
                    steps: [
                        .summarizing("clone", milliseconds: [900, 1100, 1000]),
                        BenchmarkStep(name: "disk-write", durationMs: 2000, throughput: 268_435_456),
                        BenchmarkStep(name: "swift-build", durationMs: 0, note: "no Swift toolchain", skipped: true),
                    ]),
                BenchmarkSuiteResult.skipped("boot", runtime: .host, reason: "needs --include-host"),
                BenchmarkSuiteResult(
                    name: "toolchains", runtime: "docker", platform: "linux", status: .ran,
                    toolchains: [
                        ToolchainBenchRow(
                            tool: "go", platform: "linux", runtime: "docker", installer: "mise go@latest",
                            status: .ran, installMs: 41_000, verifyMs: 120, workloadMs: 900, workload: "go build"),
                        ToolchainBenchRow(
                            tool: "vault", platform: "linux", runtime: "docker", installer: "mise vault@latest",
                            status: .ran, verifyMs: 80, skipReason: "every vault command talks to a Vault server"),
                    ]),
            ])
    }

    func testAReportSurvivesAJSONRoundTrip() throws {
        let report = makeReport()
        let data = try BenchmarkReportStore.encoder().encode(report)
        let decoded = try BenchmarkReportStore.decoder().decode(BenchmarkReport.self, from: data)
        XCTAssertEqual(decoded.runID, report.runID)
        XCTAssertEqual(decoded.suites, report.suites)
        XCTAssertEqual(decoded.host, report.host)
        XCTAssertEqual(decoded.setup, report.setup)
        XCTAssertEqual(decoded.elapsedSeconds, 90, accuracy: 1)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"installMs\""))
        XCTAssertTrue(text.contains("\"skipReason\""))
    }

    func testStepSummaryIsTheMedianWithItsBounds() {
        let odd = BenchmarkStep.summarizing("x", milliseconds: [30, 10, 20])
        XCTAssertEqual(odd.durationMs, 20)
        XCTAssertEqual(odd.minMs, 10)
        XCTAssertEqual(odd.maxMs, 30)
        XCTAssertEqual(odd.samples, 3)
        XCTAssertEqual(BenchmarkStep.summarizing("x", milliseconds: [10, 20, 30, 50]).durationMs, 25)
        XCTAssertEqual(BenchmarkStep.summarizing("x", milliseconds: [7]).durationMs, 7)
        XCTAssertEqual(BenchmarkStep.summarizing("x", milliseconds: []).durationMs, 0)
    }

    func testTheStoreWritesPrivateFilesInAPrivateDirectory() throws {
        let store = BenchmarkReportStore(directory: directory)
        let url = try store.write(makeReport())
        let dirMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int)
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        XCTAssertEqual(dirMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("results-"))
        XCTAssertEqual(try store.load(url).runID, "bench-20261008-101010-abcd")
    }

    func testHistoryIsNewestFirstAndPrunedToTheLimit() throws {
        let store = BenchmarkReportStore(directory: directory)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<7 {
            try store.write(
                makeReport(
                    runID: "bench-run-\(String(format: "%04d", index))",
                    started: base.addingTimeInterval(Double(index) * 100)),
                keep: 4)
        }
        let entries = store.list()
        XCTAssertEqual(entries.count, 4, "only the newest are kept")
        XCTAssertEqual(entries.map(\.runID), ["bench-run-0006", "bench-run-0005", "bench-run-0004", "bench-run-0003"])
        XCTAssertEqual(store.latest()?.runID, "bench-run-0006")
    }

    func testAnUnreadableFileIsSkippedNotFatal() throws {
        let store = BenchmarkReportStore(directory: directory)
        try store.write(makeReport())
        try Data("not json".utf8).write(to: directory.appendingPathComponent("results-garbage.json"))
        XCTAssertEqual(store.list().count, 1)
    }

    func testAnEmptyHistoryHasNoLatest() {
        XCTAssertNil(BenchmarkReportStore(directory: directory).latest())
        XCTAssertEqual(BenchmarkReportStore(directory: directory).list(), [])
    }

    func testOnlyFailedWorkCountsAsAFailure() {
        var report = makeReport()
        XCTAssertFalse(report.hasFailures, "skipped suites and verify-only toolchains are not failures")
        report.suites[2].toolchains?[0].status = .failed
        XCTAssertTrue(report.hasFailures, "a toolchain that did not install or build fails the run")
        report.suites[2].toolchains?[0].status = .ran
        report.suites[0].status = .failed
        XCTAssertTrue(report.hasFailures)
    }

    func testAReportCarriesNoCredentialShapedFields() throws {
        let text = String(decoding: try BenchmarkReportStore.encoder().encode(makeReport()), as: UTF8.self).lowercased()
        for needle in ["token", "password", "secret", "authorization"] {
            XCTAssertFalse(text.contains(needle), "a report must never carry '\(needle)'")
        }
    }

    func testScratchWritesPrivateFilesAndRemovesItself() throws {
        let scratch = BenchmarkScratch(benchRoot: directory, runID: "bench-x")
        try scratch.create()
        let file = try scratch.write(Data("x".utf8), to: "a/b/payload.bin")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        let dirMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: scratch.root.path)[.posixPermissions] as? Int)
        XCTAssertEqual(dirMode & 0o777, 0o700)
        scratch.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.root.path))
        scratch.remove()  // idempotent
    }

    func testGeneratedSwiftPackageHasAnExecutableAndAsManyLibraryFilesAsAsked() {
        let files = BenchmarkScratch.swiftPackageFiles(count: 5)
        XCTAssertEqual(files.filter { $0.path.hasPrefix("Sources/BenchLib/") }.count, 5)
        XCTAssertTrue(files.contains { $0.path == "Package.swift" })
        XCTAssertTrue(files.contains { $0.path == "Sources/BenchApp/main.swift" })
    }
}
