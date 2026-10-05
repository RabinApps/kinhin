import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The App section's "Reset kinhin…" flow: the three gates (scope pick, plan
/// confirm, typed word), the preferences wipe for config-scoped resets, and
/// what the delegate is told once it's done.
@MainActor
final class AppResetTests: MainWindowTestCase {
    private var model: AppSectionModel { models.appModel }

    private func showAppSection() {
        tabs.showAdvanced(.app)
        _ = model
    }

    private func seedPrefs() {
        model.setLaunchMode(.menuBarOnly)
        model.setAutoStartFleet(true)
    }

    private func stubGates(scope: ResetScope?, planConfirmed: Bool, wordConfirmed: Bool) {
        model.chooseResetScope = { scope }
        model.confirmResetPlan = { _ in planConfirmed }
        model.confirmResetWord = { wordConfirmed }
    }

    func testCancellingTheScopePickerRunsNothing() async {
        showAppSection()
        seedPrefs()
        stubGates(scope: nil, planConfirmed: false, wordConfirmed: false)
        var planned: [ResetScope] = []
        model.resetPlanner = { scope in
            planned.append(scope)
            return await ResetEverything.plan(
                scope: scope, configURL: self.scratchConfig, supportRoot: self.supportRoot())
        }

        model.resetClicked()
        await waitUntil("the flow settles") { !self.model.resetBusy }
        XCTAssertTrue(planned.isEmpty, "a cancelled scope pick must not even build a plan")
        XCTAssertTrue(model.resetLine.text.isEmpty)
        XCTAssertEqual(AppPreferences.launchMode(in: suite), .menuBarOnly, "nothing was cleared")
        XCTAssertTrue(delegate.resetFinishedScopes.isEmpty)
    }

    func testDecliningThePlanRunsNothing() async {
        showAppSection()
        stubGates(scope: .config, planConfirmed: false, wordConfirmed: false)
        var ranPlans: [ResetPlan] = []
        model.resetRunner = { plan in
            ranPlans.append(plan)
            return []
        }

        model.resetClicked()
        await waitUntil("the flow settles") { !self.model.resetBusy }
        XCTAssertTrue(ranPlans.isEmpty, "declining the plan must not wipe anything")
        XCTAssertTrue(delegate.resetFinishedScopes.isEmpty)
    }

    func testDecliningTheTypedWordRunsNothing() async {
        showAppSection()
        stubGates(scope: .config, planConfirmed: true, wordConfirmed: false)
        var ranPlans: [ResetPlan] = []
        model.resetRunner = { plan in
            ranPlans.append(plan)
            return []
        }

        model.resetClicked()
        await waitUntil("the flow settles") { !self.model.resetBusy }
        XCTAssertTrue(ranPlans.isEmpty, "the typed word is the last gate: no word, no wipe")
        XCTAssertTrue(delegate.resetFinishedScopes.isEmpty)
    }

    func testConfirmedConfigResetClearsPrefsAndTellsTheDelegate() async throws {
        showAppSection()
        seedPrefs()
        let plan = ResetPlan(scope: .config, supportRoot: supportRoot())
        stubGates(scope: .config, planConfirmed: true, wordConfirmed: true)
        model.resetPlanner = { _ in plan }
        var ranPlans: [ResetPlan] = []
        var stopped = false
        model.resetRunner = { ran in
            ranPlans.append(ran)
            return ["removed config, logs and state"]
        }
        model.fleetController = fleet

        model.resetClicked()
        await waitUntil("the reset finishes") { !self.model.resetBusy && !self.model.resetLine.text.isEmpty }
        XCTAssertEqual(ranPlans, [plan])
        XCTAssertEqual(delegate.resetFinishedScopes, [.config])
        XCTAssertEqual(AppPreferences.launchMode(in: suite), AppPreferences.defaultMode, "prefs were cleared")
        XCTAssertFalse(AppPreferences.autoStartFleet(in: suite))
        XCTAssertEqual(model.launchMode, AppPreferences.defaultMode, "the card re-reads the cleared prefs")
        XCTAssertFalse(model.autoStartFleet)
        XCTAssertEqual(model.resetLine.style, .ok, model.resetLine.text)
    }

    func testDaemonResetKeepsThePrefs() async {
        showAppSection()
        seedPrefs()
        stubGates(scope: .daemon, planConfirmed: true, wordConfirmed: true)
        let plan = ResetPlan(scope: .daemon, supportRoot: supportRoot())
        model.resetPlanner = { _ in plan }
        model.resetRunner = { _ in ["removed the daemon LaunchAgent"] }

        model.resetClicked()
        await waitUntil("the reset finishes") { !self.model.resetBusy }
        XCTAssertEqual(delegate.resetFinishedScopes, [.daemon])
        XCTAssertEqual(
            AppPreferences.launchMode(in: suite), .menuBarOnly,
            "a daemon reset does not touch the app's preferences")
    }

    func testDaemonResetStopsTheFleetFirst() async {
        showAppSection()
        model.fleetController = fleet
        fake.status.running = true
        stubGates(scope: .daemon, planConfirmed: true, wordConfirmed: true)
        let plan = ResetPlan(scope: .daemon, supportRoot: supportRoot())
        model.resetPlanner = { _ in plan }
        model.resetRunner = { _ in ["removed the daemon LaunchAgent"] }

        model.resetClicked()
        await waitUntil("the reset finishes") { !self.model.resetBusy }
        XCTAssertTrue(fake.calls.contains("stop"), "the fleet is stopped before the wipe: \(fake.calls)")
    }

    func testConfigResetDoesNotStopTheFleet() async {
        showAppSection()
        model.fleetController = fleet
        stubGates(scope: .config, planConfirmed: true, wordConfirmed: true)
        let plan = ResetPlan(scope: .config, supportRoot: supportRoot())
        model.resetPlanner = { _ in plan }
        model.resetRunner = { _ in ["removed config, logs and state"] }

        model.resetClicked()
        await waitUntil("the reset finishes") { !self.model.resetBusy }
        XCTAssertFalse(fake.calls.contains("stop"), "a config reset leaves the fleet alone: \(fake.calls)")
    }

    func testAFailedResetIsSurfacedAndNotReportedAsFinished() async {
        showAppSection()
        stubGates(scope: .daemon, planConfirmed: true, wordConfirmed: true)
        let plan = ResetPlan(scope: .daemon, supportRoot: supportRoot())
        model.resetPlanner = { _ in plan }
        model.resetRunner = { _ in throw ResetTestError.deliberate }

        model.resetClicked()
        await waitUntil("the failure lands") { !self.model.resetBusy }
        XCTAssertEqual(model.resetLine.style, .error, model.resetLine.text)
        XCTAssertTrue(delegate.resetFinishedScopes.isEmpty, "a failed reset must not re-bootstrap")
    }

    func testResetIsIgnoredWhileOneIsRunning() async {
        showAppSection()
        stubGates(scope: .config, planConfirmed: true, wordConfirmed: true)
        let plan = ResetPlan(scope: .config, supportRoot: supportRoot())
        model.resetPlanner = { _ in plan }
        let gate = Mutex(false)
        model.resetRunner = { _ in
            // Hold the wipe until the second click has been attempted.
            while !gate.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(5))  // released by the test below
            }
            return []
        }

        model.resetClicked()
        await waitUntil("the reset is busy") { self.model.resetBusy }
        model.resetClicked()  // ignored: busy
        gate.withLock { $0 = true }
        await waitUntil("the reset finishes") { !self.model.resetBusy }
        XCTAssertEqual(delegate.resetFinishedScopes, [.config], "exactly one reset ran")
    }

    private func supportRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-apptest-\(UUID().uuidString)")
    }
}

private enum ResetTestError: Error { case deliberate }
