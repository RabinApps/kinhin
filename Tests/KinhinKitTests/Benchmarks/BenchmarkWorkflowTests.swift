import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class BenchmarkWorkflowTests: XCTestCase {
    private var harness: BenchHarness!

    override func setUp() {
        super.setUp()
        harness = BenchHarness()
    }

    override func tearDown() {
        harness.cleanUp()
        super.tearDown()
    }

    private func run(_ options: BenchmarkOptions) async throws -> BenchmarkReport {
        var env = harness.makeEnvironment()
        env.drainPoll = .milliseconds(1)
        return try await BenchmarkRunner(environment: env).run(options)
    }

    // MARK: - Casual

    func testCasualRunsEveryStepInOneSharedVM() async throws {
        let report = try await run(BenchmarkOptions(suites: [.casual], runtimes: [.tart]))
        let casual = try XCTUnwrap(report.suite("casual", runtime: .tart))
        XCTAssertEqual(casual.status, .ran, casual.error ?? "")
        XCTAssertEqual(
            casual.steps.map(\.name),
            ["exec-overhead", "file-create", "tar-gzip", "untar", "checksum", "git-commit", "swift-build"])
        XCTAssertEqual(casual.platform, "macOS")
        XCTAssertEqual(harness.clonedNames.count, 1, "one bench VM serves the whole suite")
        XCTAssertEqual(casual.steps[0].samples, BenchmarkProfile.make(.quick, iterations: nil).overheadLoops)
        let fileCreate = try XCTUnwrap(casual.steps.first { $0.name == "file-create" })
        XCTAssertNotNil(fileCreate.throughput, "data-moving steps report bytes per second")
    }

    func testCasualSkipsSwiftBuildWhenTheImageHasNoToolchain() async throws {
        let profile = BenchmarkProfile.make(.quick, iterations: nil)
        // uname (0), overhead loops, file-create, tar, untar, checksum, git setup + commit, then the swift probe.
        harness.ssh.failOnCall = 1 + profile.overheadLoops + 4 + 2
        let report = try await run(BenchmarkOptions(suites: [.casual], runtimes: [.tart]))
        let casual = try XCTUnwrap(report.suite("casual", runtime: .tart))
        XCTAssertEqual(casual.status, .ran, casual.error ?? "")
        let swift = try XCTUnwrap(casual.steps.last)
        XCTAssertEqual(swift.name, "swift-build")
        XCTAssertEqual(swift.skipped, true)
        XCTAssertEqual(swift.note, "no Swift toolchain in the image")
    }

    func testCasualStepsRunInsideTheScratchDirectoryWithTheToolPath() async throws {
        _ = try await run(BenchmarkOptions(suites: [.casual], runtimes: [.tart]))
        let scripts = harness.ssh.scripts
        let tar = try XCTUnwrap(scripts.first { $0.contains("tar -czf tree.tgz") })
        XCTAssertTrue(tar.contains("set -euo pipefail"))
        XCTAssertTrue(tar.contains(#"BENCH="$HOME/kinhin-bench""#))
        XCTAssertTrue(tar.contains("/opt/homebrew/bin"), "an SSH shell skips the login profile")
        XCTAssertTrue(scripts.contains { $0.contains("rm -rf tree base.bin") }, "the suite cleans up after itself")
    }

    func testAFailingStepFailsTheSuiteAndKeepsThePartialSteps() async throws {
        // uname (0), then the overhead loops, then file-create is the first scripted step.
        let profile = BenchmarkProfile.make(.quick, iterations: nil)
        harness.ssh.failOnCall = 1 + profile.overheadLoops + 1  // tar-gzip
        let report = try await run(BenchmarkOptions(suites: [.casual], runtimes: [.tart]))
        let casual = try XCTUnwrap(report.suite("casual", runtime: .tart))
        XCTAssertEqual(casual.status, .failed)
        XCTAssertTrue(casual.error?.contains("tar-gzip") == true, casual.error ?? "")
        XCTAssertEqual(casual.steps.map(\.name), ["exec-overhead", "file-create"])
        XCTAssertTrue(harness.tart.vms.isEmpty)
    }

    func testCasualOnALinuxContainerUsesTheLinuxToolPath() async throws {
        let report = try await run(BenchmarkOptions(suites: [.casual], runtimes: [.docker]))
        let casual = try XCTUnwrap(report.suite("casual", runtime: .docker))
        XCTAssertEqual(casual.status, .ran, casual.error ?? "")
        XCTAssertEqual(casual.platform, "linux")
        let script = try XCTUnwrap(
            harness.docker.argvSnapshot().compactMap { $0.last }.first { $0.contains("tar -czf tree.tgz") })
        XCTAssertFalse(script.contains("/opt/homebrew"))
        XCTAssertTrue(script.contains("/opt/flutter/bin"))
    }

    func testTheWorkloadSuitesDefaultToTheFleetsPrimaryRuntime() async throws {
        var config = harness.config
        config.container = nil
        config.docker = nil
        harness.config = config
        let report = try await run(BenchmarkOptions(suites: [.casual]))
        XCTAssertEqual(report.suites.map(\.runtime), ["tart"])
    }

    // MARK: - Xcode

    func testXcodeIsSkippedWhenTheGuestHasNoXcodebuild() async throws {
        harness.ssh.failOnCall = 1  // the xcodebuild -version probe, right after the guest probe
        let report = try await run(BenchmarkOptions(suites: [.xcode]))
        let xcode = try XCTUnwrap(report.suite("xcode", runtime: .tart))
        XCTAssertEqual(xcode.status, .skipped)
        XCTAssertTrue(xcode.skipReason?.contains("bake Xcode into the image") == true)
    }

    func testXcodeBuildsAGeneratedPackageCleanThenIncrementally() async throws {
        let report = try await run(BenchmarkOptions(suites: [.xcode]))
        let xcode = try XCTUnwrap(report.suite("xcode", runtime: .tart))
        XCTAssertEqual(xcode.status, .ran, xcode.error ?? "")
        XCTAssertEqual(xcode.steps.map(\.name), ["clean-build", "incremental-build"])
        let scripts = harness.ssh.scripts
        XCTAssertTrue(
            scripts.contains { $0.contains("Sources/BenchLib/Gen119.swift") }, "quick sizing: 120 generated files")
        let incremental = try XCTUnwrap(scripts.last { $0.contains("xcodebuild -scheme BenchLib") })
        XCTAssertTrue(incremental.contains("touched by kinhin bench"))
        XCTAssertFalse(incremental.contains("rm -rf ../dd"), "an incremental build keeps derived data")
    }

    func testXcodeNeedsAMacOSGuest() async throws {
        // A Linux tart image is not a macOS guest.
        harness.ssh.setStdout("Linux", forCall: 0)
        let linux = try await run(BenchmarkOptions(suites: [.xcode]))
        let xcode = try XCTUnwrap(linux.suite("xcode", runtime: .tart))
        XCTAssertEqual(xcode.status, .skipped)
        XCTAssertEqual(xcode.skipReason, "Xcode needs a macOS guest")
    }

    func testProjectModeCopiesTheCheckoutAndBuildsIt() async throws {
        let project = harness.root.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("let x = 1\n".utf8).write(to: project.appendingPathComponent("Sources/main.swift"))
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: project.appendingPathComponent(".git/config"))

        var env = harness.makeEnvironment()
        env.shell = RealTarShell()
        let report = try await BenchmarkRunner(environment: env).run(
            BenchmarkOptions(suites: [.xcode], projectPath: project.path))
        let xcode = try XCTUnwrap(report.suite("xcode", runtime: .tart))
        XCTAssertEqual(xcode.status, .ran, xcode.error ?? "")
        XCTAssertEqual(xcode.steps.map(\.name), ["project-copy", "clean-build", "incremental-build"])
        let upload = try XCTUnwrap(harness.ssh.scripts.first { $0.contains("KINHIN_BENCH_B64") })
        XCTAssertTrue(upload.contains("tar -x -C project"), "extraction stays inside the project directory")
        XCTAssertTrue(upload.contains("base64 --decode"))
        let base64 = upload.components(separatedBy: "KINHIN_BENCH_B64").dropFirst().first ?? ""
        let archive = Data(
            base64Encoded: base64.replacingOccurrences(of: "'", with: "").trimmingCharacters(
                in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters)
        XCTAssertNotNil(archive)
        XCTAssertFalse(String(decoding: archive ?? Data(), as: UTF8.self).contains("secret"), ".git is excluded")
    }

    func testProjectBuildGivesABarePackageADestination() {
        // Found by a real run: xcodebuild refuses a Swift package without -destination.
        let script = BenchmarkScripts.projectBuild(incremental: false)
        XCTAssertTrue(script.contains("xcodebuild -destination 'generic/platform=macOS' \"$@\""))
        XCTAssertTrue(script.contains("xcodebuild -workspace"), "workspaces and projects keep their own destinations")
    }

    // MARK: - Large

    func testLargeMeasuresDiskThenCPU() async throws {
        let report = try await run(BenchmarkOptions(suites: [.large], runtimes: [.tart]))
        let large = try XCTUnwrap(report.suite("large", runtime: .tart))
        XCTAssertEqual(large.status, .ran, large.error ?? "")
        XCTAssertEqual(large.steps.map(\.name), ["disk-write", "disk-read", "disk-checksum", "cpu-gzip"])
        let write = try XCTUnwrap(harness.ssh.scripts.first { $0.contains("dd if=/dev/zero of=blob.bin") })
        XCTAssertTrue(write.contains("count=512"), "quick: a 512 MB blob")
        XCTAssertTrue(harness.ssh.scripts.contains { $0.contains("rm -f blob.bin") }, "the blob is removed afterwards")
    }

    func testThoroughLargeStaysUnderTheHardCap() async throws {
        let report = try await run(BenchmarkOptions(suites: [.large], intensity: .thorough, runtimes: [.tart]))
        XCTAssertEqual(report.suite("large", runtime: .tart)?.status, .ran)
        let write = try XCTUnwrap(harness.ssh.scripts.first { $0.contains("dd if=/dev/zero of=blob.bin") })
        let count = try XCTUnwrap(
            write.components(separatedBy: "count=").dropFirst().first.flatMap { Int($0.prefix(while: \.isNumber)) })
        XCTAssertLessThanOrEqual(count, BenchmarkLimits.maxPayloadMB)
    }

    func testTheNetworkCloneRunsOnlyWithAURLAndOnlyForGitSchemes() async throws {
        let offline = try await run(BenchmarkOptions(suites: [.large], runtimes: [.tart]))
        XCTAssertFalse(try XCTUnwrap(offline.suite("large", runtime: .tart)).steps.contains { $0.name == "git-clone" })

        let url = "https://github.com/apple/swift-argument-parser.git"
        let online = try await run(BenchmarkOptions(suites: [.large], runtimes: [.tart], networkURL: url))
        XCTAssertTrue(try XCTUnwrap(online.suite("large", runtime: .tart)).steps.contains { $0.name == "git-clone" })
        let clone = try XCTUnwrap(harness.ssh.scripts.first { $0.contains("git clone") })
        XCTAssertTrue(clone.contains("GIT_ALLOW_PROTOCOL=https:ssh:git"))
        XCTAssertTrue(clone.contains("-- '\(url)'"), "the URL is quoted and cannot be read as an option")

        do {
            _ = try await run(BenchmarkOptions(suites: [.large], networkURL: "ext::sh -c id"))
            XCTFail("expected an invalid option")
        } catch BenchmarkError.invalidOption {
        }
    }
}

/// Runs `tar` for real (the project archive is built on the host) but nothing else.
private struct RealTarShell: ShellRunning {
    func run(_ argv: [String], cwd: URL?, timeout: TimeInterval) async throws -> ShellResult {
        try await Shell().run(argv, cwd: cwd, timeout: timeout)
    }
}
