import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ToolchainBenchmarkRunTests: XCTestCase {
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

    private func rows(_ report: BenchmarkReport, runtime: RuntimeID) throws -> [String: ToolchainBenchRow] {
        let suite = try XCTUnwrap(report.suite("toolchains", runtime: runtime))
        return Dictionary(uniqueKeysWithValues: (suite.toolchains ?? []).map { ($0.tool, $0) })
    }

    // MARK: - Quick

    func testQuickTimesVerifyAndWorkloadButNeverInstalls() async throws {
        let report = try await run(
            BenchmarkOptions(suites: [.toolchains], runtimes: [.tart], toolchains: ["go", "jq", "playwright"]))
        let rows = try rows(report, runtime: .tart)
        XCTAssertEqual(Set(rows.keys), ["go", "jq", "playwright"])

        let go = try XCTUnwrap(rows["go"])
        XCTAssertEqual(go.status, .ran)
        XCTAssertNil(go.installMs, "quick runs do not install")
        XCTAssertNotNil(go.verifyMs)
        XCTAssertNotNil(go.workloadMs)
        XCTAssertEqual(go.workload, "go build")
        XCTAssertEqual(go.installer, "mise go@latest")
        XCTAssertEqual(go.platform, "macOS")
        XCTAssertEqual(go.runtime, "tart")

        let playwright = try XCTUnwrap(rows["playwright"])
        XCTAssertEqual(playwright.status, .ran)
        XCTAssertNil(playwright.workloadMs)
        XCTAssertNotNil(playwright.skipReason, "verify-only rows say why")
        XCTAssertFalse(harness.ssh.scripts.contains { $0.contains("mise use --global") }, "nothing is installed")
        XCTAssertEqual(harness.clonedNames.count, 1, "one shared VM per platform")
    }

    func testQuickReportsAMissingToolAsSkipped() async throws {
        harness.ssh.failOnCall = 1  // the verify right after the guest probe
        let report = try await run(BenchmarkOptions(suites: [.toolchains], runtimes: [.tart], toolchains: ["go"]))
        let go = try XCTUnwrap(rows(report, runtime: .tart)["go"])
        XCTAssertEqual(go.status, .skipped)
        XCTAssertNil(go.verifyMs)
        XCTAssertTrue(go.skipReason?.contains("not installed in this image") == true)
    }

    func testAWorkloadThatExits77IsSkippedWithItsReason() async throws {
        harness.docker.execResults = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),  // cmake's guest packages
            ShellResult(exitCode: 0, stdout: "", stderr: ""),  // verify
            ShellResult(exitCode: 77, stdout: "no C++ compiler in the guest\n", stderr: ""),
        ]
        let report = try await run(BenchmarkOptions(suites: [.toolchains], runtimes: [.docker], toolchains: ["cmake"]))
        let cmake = try XCTUnwrap(rows(report, runtime: .docker)["cmake"])
        XCTAssertEqual(cmake.status, .ran)
        XCTAssertEqual(cmake.skipReason, "no C++ compiler in the guest")
        XCTAssertNil(cmake.workloadMs)
        XCTAssertEqual(cmake.platform, "linux")
    }

    func testAFailingWorkloadFailsOnlyItsRow() async throws {
        harness.docker.execResults = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 1, stdout: "", stderr: "go: no such file"),
        ]
        let report = try await run(
            BenchmarkOptions(suites: [.toolchains], runtimes: [.docker], toolchains: ["go", "jq"]))
        let rows = try rows(report, runtime: .docker)
        XCTAssertEqual(rows["go"]?.status, .failed)
        XCTAssertTrue(rows["go"]?.note?.contains("workload failed") == true)
        XCTAssertEqual(rows["jq"]?.status, .ran, "the next entry still runs")
    }

    // MARK: - Thorough

    func testThoroughMarksAnAlreadyBakedToolAsPreinstalledAndSkipsItsInstall() async throws {
        let report = try await run(
            BenchmarkOptions(suites: [.toolchains], intensity: .thorough, runtimes: [.tart], toolchains: ["jq"]))
        let jq = try XCTUnwrap(rows(report, runtime: .tart)["jq"])
        XCTAssertEqual(jq.note, "preinstalled")
        XCTAssertNil(jq.installMs)
        XCTAssertNotNil(jq.verifyMs)
        XCTAssertFalse(harness.ssh.scripts.contains { $0.contains("mise use --global") })
    }

    func testThoroughTimesTheColdInstallThenVerifiesIt() async throws {
        harness.ssh.failOnCall = 1  // the pre-install verify fails: the tool is not in the image
        let report = try await run(
            BenchmarkOptions(suites: [.toolchains], intensity: .thorough, runtimes: [.tart], toolchains: ["jq"]))
        let jq = try XCTUnwrap(rows(report, runtime: .tart)["jq"])
        XCTAssertEqual(jq.status, .ran)
        XCTAssertNotNil(jq.installMs)
        XCTAssertNotNil(jq.verifyMs)
        XCTAssertNil(jq.note)
        let install = try XCTUnwrap(harness.ssh.scripts.first { $0.contains("mise use --global") })
        XCTAssertTrue(install.contains("'jq@latest'"))
        XCTAssertFalse(install.contains("kinhin-cache"), "the install is cold: no shared cache")
    }

    func testAFailedInstallFailsTheRowWithItsOutput() async throws {
        harness.docker.execResults = [
            ShellResult(exitCode: 1, stdout: "", stderr: ""),  // not preinstalled
            ShellResult(exitCode: 1, stdout: "", stderr: "mise: download failed"),
        ]
        let report = try await run(
            BenchmarkOptions(suites: [.toolchains], intensity: .thorough, runtimes: [.docker], toolchains: ["jq"]))
        let jq = try XCTUnwrap(rows(report, runtime: .docker)["jq"])
        XCTAssertEqual(jq.status, .failed)
        XCTAssertTrue(
            jq.note?.contains("install failed") == true && jq.note?.contains("download failed") == true, jq.note ?? "")
    }

    func testRequirementsAreInstalledUntimedBeforeTheTool() async throws {
        harness.ssh.failOnCall = 1  // node is missing
        let report = try await run(
            BenchmarkOptions(suites: [.toolchains], intensity: .thorough, runtimes: [.tart], toolchains: ["typescript"])
        )
        let typescript = try XCTUnwrap(rows(report, runtime: .tart)["typescript"])
        XCTAssertEqual(typescript.status, .ran)
        XCTAssertEqual(typescript.note, "preinstalled", "typescript itself was already there; only node was installed")
        XCTAssertTrue(harness.ssh.scripts.contains { $0.contains("mise use --global 'node@22'") })
    }

    func testTartThoroughBootsOneVMPerCategory() async throws {
        let report = try await run(
            BenchmarkOptions(
                suites: [.toolchains], intensity: .thorough, runtimes: [.tart],
                toolchains: ["go", "node", "typescript", "jq", "terraform"]))
        XCTAssertEqual(try rows(report, runtime: .tart).count, 5)
        // languages (go, node), javascript (typescript), build (jq), cloud (terraform).
        XCTAssertEqual(harness.clonedNames.count, 4)
        XCTAssertEqual(Set(harness.tart.deleteCalls), Set(harness.clonedNames), "every category VM is deleted")
        XCTAssertTrue(harness.tart.vms.isEmpty)
    }

    func testContainersGetAFreshContainerPerTool() async throws {
        let report = try await run(
            BenchmarkOptions(
                suites: [.toolchains], intensity: .thorough, runtimes: [.docker], toolchains: ["jq", "yq", "just"]))
        XCTAssertEqual(try rows(report, runtime: .docker).count, 3)
        let created = harness.docker.argvSnapshot().filter { $0.dropFirst().first == "run" }
        XCTAssertEqual(created.count, 3)
        XCTAssertTrue(harness.docker.containers.isEmpty)
    }

    // MARK: - Platforms

    func testALinuxTartImageRunsTheLinuxPlans() async throws {
        harness.ssh.setStdout("Linux", forCall: 0)
        let report = try await run(
            BenchmarkOptions(suites: [.toolchains], runtimes: [.tart], toolchains: ["react-native", "dotnet", "jq"]))
        let suite = try XCTUnwrap(report.suite("toolchains", runtime: .tart))
        XCTAssertEqual(suite.platform, "linux")
        XCTAssertEqual(Set(try rows(report, runtime: .tart).keys), ["dotnet", "jq"], "react-native is macOS-only")
    }

    func testNoToolchainForTheGuestPlatformIsASkippedSuite() async throws {
        let report = try await run(
            BenchmarkOptions(suites: [.toolchains], runtimes: [.docker], toolchains: ["react-native"]))
        let suite = try XCTUnwrap(report.suite("toolchains", runtime: .docker))
        XCTAssertEqual(suite.status, .skipped)
        XCTAssertTrue(harness.docker.containers.isEmpty)
    }

    func testTheDefaultSelectionCoversTartAndTheFirstLinuxRuntime() async throws {
        let report = try await run(BenchmarkOptions(suites: [.toolchains], toolchains: ["jq"]))
        XCTAssertEqual(report.suites.map(\.runtime), ["tart", "appleContainer"])
    }

    // MARK: - Guest prerequisites

    func testLinuxGuestsGetTheirBuildPrerequisitesUntimed() async throws {
        harness.docker.execResults = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),  // guest packages
            ShellResult(exitCode: 1, stdout: "", stderr: ""),  // not preinstalled
        ]
        let report = try await run(
            BenchmarkOptions(suites: [.toolchains], intensity: .thorough, runtimes: [.docker], toolchains: ["lua"]))
        let lua = try XCTUnwrap(rows(report, runtime: .docker)["lua"])
        XCTAssertEqual(lua.status, .ran, lua.note ?? "")
        let apt = try XCTUnwrap(
            harness.docker.argvSnapshot().compactMap(\.last).first { $0.contains("apt-get install") })
        XCTAssertTrue(apt.contains("'build-essential'"))
    }

    func testPrerequisitePackagesApplyToLinuxOnly() {
        XCTAssertEqual(
            ToolchainBenchPlan.plans(platform: .linux, ids: ["lua"]).first?.guestPackages.first, "build-essential")
        XCTAssertEqual(ToolchainBenchPlan.plans(platform: .macOS, ids: ["lua"]).first?.guestPackages, [])
        XCTAssertEqual(ToolchainBenchPlan.plans(platform: .linux, ids: ["elixir"]).first?.requires, ["erlang"])
        XCTAssertEqual(ToolchainBenchPlan.plans(platform: .macOS, ids: ["elixir"]).first?.requires, [])
    }

    func testAnInstallThatDiedForWantOfDiskIsSkippedNotFailed() async throws {
        harness.docker.execResults = [
            ShellResult(exitCode: 1, stdout: "", stderr: ""),  // not preinstalled
            ShellResult(exitCode: 1, stdout: "", stderr: "failed to extract tar: no space left on device"),
            ShellResult(exitCode: 0, stdout: "1048576\n", stderr: ""),  // df: 1 GB free
        ]
        let report = try await run(
            BenchmarkOptions(suites: [.toolchains], intensity: .thorough, runtimes: [.docker], toolchains: ["jq"]))
        let jq = try XCTUnwrap(rows(report, runtime: .docker)["jq"])
        XCTAssertEqual(jq.status, .skipped)
        XCTAssertTrue(jq.skipReason?.contains("only 1.0 GB free") == true, jq.skipReason ?? "")
        XCTAssertFalse(report.hasFailures)
    }

    func testAnInstallFailureWithRoomToSpareStaysAFailure() async throws {
        harness.docker.execResults = [
            ShellResult(exitCode: 1, stdout: "", stderr: ""),
            ShellResult(exitCode: 1, stdout: "", stderr: "failed to extract tar: corrupt archive"),
            ShellResult(exitCode: 0, stdout: "52428800\n", stderr: ""),  // 50 GB free
        ]
        let report = try await run(
            BenchmarkOptions(suites: [.toolchains], intensity: .thorough, runtimes: [.docker], toolchains: ["jq"]))
        XCTAssertEqual(try rows(report, runtime: .docker)["jq"]?.status, .failed)
        XCTAssertTrue(report.hasFailures)
    }
}
