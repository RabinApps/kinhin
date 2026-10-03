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
}
