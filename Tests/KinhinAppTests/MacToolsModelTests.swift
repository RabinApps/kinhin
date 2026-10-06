import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The busy action behind "This Mac" (and the wizard, which reuses the form):
/// its task is retained so the Cancel button can stop it, and a cancelled
/// build says so instead of reporting a failure.
@MainActor
final class MacToolsModelTests: XCTestCase {
    private var scratch: URL!
    private var configURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinhin-mactools-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        configURL = scratch.appendingPathComponent("config.yaml")
    }

    override func tearDown() async throws {
        try await super.tearDown()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeModel() -> MacToolsModel {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        return model
    }

    /// Waits (bounded) until `condition` holds, polling because the state
    /// flips in the action's task. The `try?` is fine — this is a bounded
    /// test convenience; a cancelled waiter just returns early.
    private func waitUntil(
        timeout: TimeInterval = 5, _ condition: @autoclosure () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))  // bounded poll helper; cancellation ends it early
        }
    }

    /// Regression: the "More images" block (named base images for macOS)
    /// disappeared when tart's primary base image was a Linux one — named
    /// images with distinct labels are exactly how a mixed macOS + Linux tart
    /// fleet gets its macOS images back, so tart being installed alone decides.
    func testNamedImagesStayOfferedWhenTartServesLinux() throws {
        try """
        labels: [self-hosted, macos]
        base_image: "ghcr.io/cirruslabs/ubuntu:latest"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.setTartInstalledForTesting(true)
        XCTAssertTrue(model.tartLinuxOn, "the fixture really has a Linux primary base")
        XCTAssertTrue(model.offersNamedImages, "More images must stay available for a mixed fleet")

        model.setTartInstalledForTesting(false)
        XCTAssertFalse(model.offersNamedImages, "without tart there is nothing to bake named images")
    }

    /// `tart_path:` is authoritative, exactly like the CLI, doctor and the
    /// daemon: a configured binary that is not there reads as missing (even
    /// when a real tart sits on PATH), so the form never probes the tart the
    /// fleet will not run.
    func testConfiguredTartPathThatIsMissingReadsAsNotInstalled() throws {
        try """
        labels: [self-hosted]
        tart_path: "/nonexistent/kinhin-test-tart"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let model = makeModel()
        XCTAssertFalse(model.tartInstalled, "the configured path overrides the PATH search")
        XCTAssertEqual(
            model.tartLine.text, "not installed — tart_path: /nonexistent/kinhin-test-tart does not exist",
            "the status line names the misconfigured override instead of a bare 'not installed'")
        XCTAssertEqual(model.imageLine.text, "needs tart first")
        XCTAssertFalse(model.offersNamedImages)
    }

    /// The other direction: a configured binary outside the trusted
    /// directories is found, so an installed tart is never reported missing.
    func testConfiguredTartPathIsFoundWithoutAskingPath() throws {
        try """
        labels: [self-hosted]
        tart_path: "/usr/bin/true"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let model = makeModel()
        XCTAssertTrue(model.tartInstalled, "the configured binary answers for tart")
        XCTAssertEqual(model.tartLine.text, "installed ✓", "a working override never blames the path")
        XCTAssertTrue(model.offersNamedImages)
    }

    func testRunRetainsItsTaskAndCancelRunningCancelsWithTheBuildLine() async throws {
        let model = makeModel()
        model.run(
            "Preparing the runner image — this takes a while…",
            cancelledLine: "Cancelled — the previous image is untouched"
        ) {
            try await Task.sleep(for: .seconds(10))
        }
        XCTAssertTrue(model.busy)
        XCTAssertNotNil(model.runningTask, "the action's task is retained for the Cancel button")

        model.cancelRunning()
        await waitUntil(!model.busy)

        XCTAssertFalse(model.busy)
        XCTAssertNil(model.runningTask, "the finished action clears its task")
        XCTAssertEqual(model.busyLine.text, "Cancelled — the previous image is untouched")
        XCTAssertEqual(model.busyLine.style, .warn)
    }

    func testCancelledInstallsUseTheDefaultCancelledLine() async throws {
        let model = makeModel()
        model.run("Installing tart…") {
            try await Task.sleep(for: .seconds(10))
        }
        model.cancelRunning()
        await waitUntil(!model.busy)

        XCTAssertEqual(model.busyLine.text, "Cancelled")
        XCTAssertEqual(model.busyLine.style, .warn)
    }

    func testFailuresStillReportAsBefore() async throws {
        let model = makeModel()
        model.run("Working…") {
            throw TartError.ipNotFound(vm: "vm")
        }
        await waitUntil(!model.busy)

        XCTAssertTrue(model.busyLine.text.hasPrefix("Failed —"))
        XCTAssertEqual(model.busyLine.style, .error)
        XCTAssertNil(model.runningTask)
    }

    func testCancelRunningWithoutAnActionIsANoop() {
        let model = makeModel()
        model.cancelRunning()
        XCTAssertFalse(model.busy)
    }

    // MARK: - Linux runtime choice sheet

    func testLinuxSetupOfferOpensWhenNothingIsOnAndSomethingCanRun() {
        // The model edits a config file on disk (a missing one is not
        // editable); this minimal file has no container/docker sections, so
        // nothing is on yet.
        try? "labels: [kinhin]\n".write(to: configURL, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.setTartInstalledForTesting(false)
        model.setContainerForTesting(false)
        model.setDockerForTesting(false)
        // Nothing is on yet, and the host can run at least one Linux runtime
        // (the fake host is arm64 + enough RAM, so the offer opens).
        let host = HostFacts(arm64: true, memoryGB: 8, osVersion: ProcessInfo.processInfo.operatingSystemVersion)
        let offered = LinuxRuntimeSetup.offeredOptions(on: host)
        XCTAssertFalse(offered.isEmpty, "the test host should be able to run at least one Linux runtime")
        // The form's button is visible when nothing is on and at least one option
        // can run. We can't easily render the view here, so we assert the model
        // state that drives the button: activeLinuxRuntimes is empty.
        XCTAssertTrue(model.activeLinuxRuntimes.isEmpty)
    }

    func testLinuxRuntimeChoiceWritesTheRightConfigSection() throws {
        // A blank file reads as "nothing configured yet" and the editors
        // leave it alone; start from a minimal config so the section is
        // created from defaults.
        try "labels: [kinhin]\n".write(to: configURL, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.reload()
        model.setDocker(true)
        let cfg = try ConfigLoader.load(from: configURL)
        XCTAssertNotNil(cfg.docker, "turning Docker on writes the docker section")
        XCTAssertEqual(cfg.docker?.image, "kinhin-ci-linux", "default image")

        model.setDocker(false)
        let cfg2 = try ConfigLoader.load(from: configURL)
        XCTAssertNil(cfg2.docker, "turning Docker off removes the section")
    }

    func testLinuxRuntimeChoiceSetsTartLinuxBaseImage() throws {
        // A blank file is not editable either; start minimal (no base_image).
        try "labels: [kinhin]\n".write(to: configURL, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.reload()
        model.setTartInstalledForTesting(true)
        model.setTartLinux(true)
        let cfg = try ConfigLoader.load(from: configURL)
        XCTAssertEqual(cfg.baseImage, "ghcr.io/cirruslabs/ubuntu:latest", "the default Linux base")

        model.setTartLinux(false)
        let cfg2 = try ConfigLoader.load(from: configURL)
        XCTAssertNil(cfg2.baseImage, "off clears the key so tart returns to the macOS default")
    }
}
