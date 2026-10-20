import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class BenchmarkRunnerTests: XCTestCase {
    private var harness: BenchHarness!

    override func setUp() {
        super.setUp()
        harness = BenchHarness()
    }

    override func tearDown() {
        harness.cleanUp()
        super.tearDown()
    }

    private func run(
        _ options: BenchmarkOptions, fleet: BenchmarkFleetControlling? = nil,
        configure: (inout BenchmarkEnvironment) -> Void = { _ in }
    ) async throws -> BenchmarkReport {
        var env = harness.makeEnvironment(fleet: fleet)
        env.drainPoll = .milliseconds(1)
        configure(&env)
        return try await BenchmarkRunner(environment: env).run(options)
    }

    // MARK: - Boot

    func testTartBootTimesEveryPhaseAndRemovesItsVMs() async throws {
        let report = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart]))

        let boot = try XCTUnwrap(report.suite("boot", runtime: .tart))
        XCTAssertEqual(boot.status, .ran)
        XCTAssertEqual(
            boot.steps.map(\.name),
            ["clone", "boot-to-IP", "IP-to-SSH-ready", "cold-boot-total", "warm-stop", "warm-boot"])
        XCTAssertTrue(boot.steps.allSatisfy { ($0.samples ?? 0) == 1 && $0.durationMs >= 0 })

        XCTAssertEqual(harness.clonedNames.count, 1)
        let name = try XCTUnwrap(harness.clonedNames.first)
        XCTAssertTrue(name.hasPrefix("kinhin-bench-"), name)
        XCTAssertEqual(harness.tart.cloneCalls.first?.source, harness.config.image)
        XCTAssertTrue(harness.tart.deleteCalls.contains(name))
        XCTAssertTrue(harness.tart.vms.isEmpty, "the bench VM must be gone")
        XCTAssertTrue(harness.tart.stopCalls.contains(name))
    }

    func testThoroughBootRunsThreeIterationsAndSummarizesThem() async throws {
        let report = try await run(BenchmarkOptions(suites: [.boot], intensity: .thorough, runtimes: [.tart]))
        let boot = try XCTUnwrap(report.suite("boot", runtime: .tart))
        XCTAssertEqual(harness.clonedNames.count, 3)
        for step in boot.steps {
            XCTAssertEqual(step.samples, 3)
            XCTAssertLessThanOrEqual(try XCTUnwrap(step.minMs), step.durationMs)
            XCTAssertLessThanOrEqual(step.durationMs, try XCTUnwrap(step.maxMs))
        }
        XCTAssertEqual(Set(harness.tart.deleteCalls), Set(harness.clonedNames))
    }

    func testEveryRuntimeGetsABootRow() async throws {
        // Adding a RuntimeID without bench coverage breaks this test (and the exhaustive switch in BootBenchmark).
        let report = try await run(BenchmarkOptions(suites: [.boot]))
        for runtime in RuntimeID.allCases {
            XCTAssertNotNil(report.suite("boot", runtime: runtime), "no boot row for \(runtime)")
        }
        let host = try XCTUnwrap(report.suite("boot", runtime: .host))
        XCTAssertEqual(host.status, .skipped)
        XCTAssertTrue(host.skipReason?.contains("--include-host") == true, "host needs explicit consent")
        for runtime in [RuntimeID.tart, .appleContainer, .docker] {
            XCTAssertEqual(report.suite("boot", runtime: runtime)?.status, .ran, "\(runtime)")
        }
    }

    func testContainerRuntimesTimeStartAndFirstExec() async throws {
        let report = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.appleContainer, .docker]))
        for runtime in [RuntimeID.appleContainer, .docker] {
            let boot = try XCTUnwrap(report.suite("boot", runtime: runtime))
            XCTAssertEqual(boot.status, .ran, "\(runtime): \(boot.error ?? "")")
            XCTAssertEqual(boot.steps.map(\.name), ["start", "exec-ready", "boot-total"])
            XCTAssertEqual(boot.platform, "linux/arm64")
        }
        XCTAssertTrue(harness.docker.containers.isEmpty, "the docker bench container is removed")
        XCTAssertTrue(harness.container.argvSnapshot().contains { $0.contains("delete") }, "and the apple one")
    }

    func testThoroughDockerReportsTheEmulationPassAsSkippedWithoutAnAmd64Image() async throws {
        let report = try await run(BenchmarkOptions(suites: [.boot], intensity: .thorough, runtimes: [.docker]))
        let amd64 = report.suites.first { $0.runtime == "docker" && $0.platform == "linux/amd64" }
        XCTAssertEqual(amd64?.status, .skipped)
    }

    func testThoroughDockerTimesTheEmulationPassWhenAnAmd64ImageExists() async throws {
        let report = try await run(BenchmarkOptions(suites: [.boot], intensity: .thorough, runtimes: [.docker])) {
            $0.dockerImageArchitecture = { _ in "amd64" }
        }
        let amd64 = try XCTUnwrap(report.suites.first { $0.runtime == "docker" && $0.platform == "linux/amd64" })
        XCTAssertEqual(amd64.status, .ran, amd64.error ?? "")
        XCTAssertEqual(amd64.notes, ["emulated"])
        let platforms = harness.docker.argvSnapshot().compactMap { argv -> String? in
            guard let index = argv.firstIndex(of: "--platform"), argv.indices.contains(index + 1) else { return nil }
            return argv[index + 1]
        }
        XCTAssertTrue(platforms.contains("linux/amd64"))
    }

    func testHostBootIsTaggedUnisolatedAndOnlyRunsWithConsent() async throws {
        // host-instances is shared with other runs on this machine (a persistent CI runner can keep a
        // kinhin-bench-* dir from an earlier job), so only directories this run creates count as leftovers.
        let instances = Paths.appSupport.appendingPathComponent("host-instances")
        func benchDirs() -> Set<String> {
            let entries =
                (try? FileManager.default.contentsOfDirectory(at: instances, includingPropertiesForKeys: nil)) ?? []
            return Set(entries.map(\.lastPathComponent).filter { $0.hasPrefix("kinhin-bench-") })
        }
        let before = benchDirs()
        let report = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.host], includeHost: true))
        let host = try XCTUnwrap(report.suite("boot", runtime: .host))
        XCTAssertEqual(host.status, .ran, host.error ?? "")
        XCTAssertEqual(host.notes, ["unisolated"])
        XCTAssertEqual(host.steps.map(\.name), ["spawn", "ready"])
        XCTAssertTrue(benchDirs().subtracting(before).isEmpty, "host work dir scrubbed")
    }

    // MARK: - Preflight

    func testAnUnhealthyRuntimeIsSkippedWithItsReasonNotFailed() async throws {
        harness.unready[.docker] = .missing(tool: "docker", fix: "install Docker Desktop")
        let report = try await run(BenchmarkOptions(suites: [.boot]))
        let docker = try XCTUnwrap(report.suite("boot", runtime: .docker))
        XCTAssertEqual(docker.status, .skipped)
        XCTAssertTrue(docker.skipReason?.contains("install Docker Desktop") == true, docker.skipReason ?? "")
        XCTAssertEqual(report.suite("boot", runtime: .tart)?.status, .ran)
    }

    func testANamedRuntimeThatIsNotReadyIsAnError() async {
        harness.unready[.docker] = .broken("the Docker daemon is not reachable")
        do {
            _ = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.docker]))
            XCTFail("expected an error")
        } catch BenchmarkError.runtimeUnavailable(let runtime, let why) {
            XCTAssertEqual(runtime, .docker)
            XCTAssertTrue(why.contains("not reachable"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAMissingImagePointsAtImagePrepare() async throws {
        harness.missingImages = [.tart]
        let report = try await run(BenchmarkOptions(suites: [.boot]))
        let tart = try XCTUnwrap(report.suite("boot", runtime: .tart))
        XCTAssertEqual(tart.status, .skipped)
        XCTAssertTrue(tart.skipReason?.contains("kinhin image prepare") == true)

        do {
            _ = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart]))
            XCTFail("expected an error")
        } catch BenchmarkError.imageMissing(let runtime, let image) {
            XCTAssertEqual(runtime, .tart)
            XCTAssertEqual(image, harness.config.image)
        }
    }

    func testNotEnoughFreeDiskRefusesToStart() async {
        do {
            _ = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart])) { env in
                env.hostResources = { HostResources(logicalCores: 8, memoryGB: 16, freeDiskGB: 5, arm64: true) }
            }
            XCTFail("expected an error")
        } catch BenchmarkError.insufficientDisk(_, let free) {
            XCTAssertEqual(free, 5)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(harness.tart.cloneCalls.isEmpty, "nothing is created when preflight fails")
    }

    func testLeftoverBenchInstancesAreSweptButOtherVMsAreNot() async throws {
        harness.tart.vms["kinhin-bench-dead-1"] = TartVM(name: "kinhin-bench-dead-1", source: "x", status: "stopped")
        harness.tart.vms["kinhin-12345678901-abcd"] = TartVM(
            name: "kinhin-12345678901-abcd", source: "x", status: "running")
        _ = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart]))
        XCTAssertTrue(harness.tart.deleteCalls.contains("kinhin-bench-dead-1"))
        XCTAssertFalse(harness.tart.deleteCalls.contains("kinhin-12345678901-abcd"), "a runner VM is never touched")
        XCTAssertNotNil(harness.tart.vms["kinhin-12345678901-abcd"])
    }

    // MARK: - Cleanup

    func testAFailingSuiteIsReportedAndStillCleansUp() async throws {
        harness.ssh.failWith = "permission denied"
        let report = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart]))
        let boot = try XCTUnwrap(report.suite("boot", runtime: .tart))
        XCTAssertEqual(boot.status, .failed)
        XCTAssertNotNil(boot.error)
        XCTAssertTrue(harness.tart.vms.isEmpty, "a failed boot still deletes its VM")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.root.appendingPathComponent(report.runID).path))
    }

    func testAFailedCloneLeavesNothingBehind() async throws {
        harness.tart.failNext("clone", stderr: "disk full")
        let report = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart]))
        XCTAssertEqual(report.suite("boot", runtime: .tart)?.status, .failed)
        XCTAssertTrue(harness.tart.vms.isEmpty)
        XCTAssertFalse(harness.tart.deleteCalls.isEmpty, "the half-created VM is torn down by name")
    }

    func testCancellationStopsTheRunAndRemovesEverything() async throws {
        let fleet = RecordingFleet(active: 1, busy: 0)
        harness.ssh.blockOnCall(0)
        var env = harness.makeEnvironment(fleet: fleet)
        env.drainPoll = .milliseconds(1)
        let runner = BenchmarkRunner(environment: env)
        let runID = runner.runID
        let task = Task { try await runner.run(BenchmarkOptions(suites: [.boot], runtimes: [.tart], confirmed: true)) }
        await harness.ssh.waitUntilBlocked()
        task.cancel()
        harness.ssh.releaseBlocked()
        do {
            _ = try await task.value
            XCTFail("a cancelled run must not report success")
        } catch is CancellationError {
        }
        XCTAssertTrue(harness.tart.vms.isEmpty, "cancellation removes the VM")
        XCTAssertEqual(fleet.pauses, [true, false], "and the fleet is resumed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.root.appendingPathComponent(runID).path))
    }

    func testKeepLeavesTheScratchDirectory() async throws {
        let kept = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart], keep: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.root.appendingPathComponent(kept.runID).path))
        let removed = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.root.appendingPathComponent(removed.runID).path))
    }

    // MARK: - Fleet

    func testALiveFleetNeedsConfirmationAndIsPausedThenResumed() async throws {
        let fleet = RecordingFleet(active: 2, busy: 0)
        do {
            _ = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart]), fleet: fleet)
            XCTFail("expected fleetBusy")
        } catch BenchmarkError.fleetBusy(let active, _) {
            XCTAssertEqual(active, 2)
        }
        XCTAssertEqual(fleet.pauses, [], "nothing is touched before the caller confirms")

        _ = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart], confirmed: true), fleet: fleet)
        XCTAssertEqual(fleet.pauses, [true, false])
    }

    func testAnAlreadyPausedFleetIsLeftPaused() async throws {
        let fleet = RecordingFleet(active: 0, running: true, paused: true)
        _ = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart]), fleet: fleet)
        XCTAssertEqual(fleet.pauses, [], "a deliberate pause is not ours to lift")
    }

    func testBusyVMsDrainBeforeTheRunStarts() async throws {
        let fleet = RecordingFleet(active: 1, busy: 1)
        // fleetImpact (preflight), hold's first read, then the drain polls.
        fleet.scriptBusy([1, 1, 2, 1, 0])
        _ = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart], confirmed: true), fleet: fleet)
        XCTAssertEqual(fleet.pauses, [true, false])
    }

    func testDrainTimeoutGivesUpAndResumes() async {
        let fleet = RecordingFleet(active: 1, busy: 1)
        do {
            _ = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart], confirmed: true), fleet: fleet) {
                $0.drainSeconds = 0.05
            }
            XCTFail("expected a drain timeout")
        } catch BenchmarkError.drainTimeout(let busy) {
            XCTAssertEqual(busy, 1)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(fleet.pauses, [true, false])
        XCTAssertTrue(harness.tart.cloneCalls.isEmpty)
    }

    func testForceSkipsTheDrain() async throws {
        let fleet = RecordingFleet(active: 1, busy: 3)
        let report = try await run(
            BenchmarkOptions(suites: [.boot], runtimes: [.tart], force: true, confirmed: true), fleet: fleet)
        XCTAssertEqual(report.suite("boot", runtime: .tart)?.status, .ran)
    }

    // MARK: - Report

    func testTheReportCarriesHostSetupAndIsWrittenToHistory() async throws {
        let report = try await run(BenchmarkOptions(suites: [.boot], runtimes: [.tart]))
        XCTAssertEqual(report.host.chip, "Test Chip")
        XCTAssertEqual(report.host.cores, 12)
        XCTAssertEqual(report.setup.image, harness.config.image)
        XCTAssertEqual(report.setup.vmCPU, harness.config.vm.cpuCount)
        XCTAssertEqual(report.intensity, "quick")
        XCTAssertEqual(report.kinhinVersion, kinhinVersion.current)
        let stored = try XCTUnwrap(BenchmarkReportStore(directory: harness.root).latest())
        XCTAssertEqual(stored.runID, report.runID)
    }

    func testNoScriptSentToAGuestMentionsCredentials() async throws {
        _ = try await run(BenchmarkOptions(suites: [.boot, .casual, .large], runtimes: [.tart]))
        for script in harness.ssh.scripts {
            XCTAssertFalse(script.localizedCaseInsensitiveContains("token"), "a bench script must carry no credential")
            XCTAssertFalse(script.contains("Authorization"))
        }
    }
}
