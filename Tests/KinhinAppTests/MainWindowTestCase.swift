import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Records MainTabsWindowDelegate calls so window actions can be tested
/// without touching a real engine, daemon, or NSApp.terminate.
@MainActor
final class RecordingTabsDelegate: MainTabsWindowDelegate {
    var logsCalls = 0
    var changedModes: [LaunchMode] = []
    var loginToggles: [Bool] = []
    var closeCalls = 0
    var setupFinishedCalls = 0
    var rebootstrapCalls = 0
    var resetFinishedScopes: [ResetScope] = []

    func openLogsFolder() { logsCalls += 1 }
    func launchModeChanged(_ mode: LaunchMode) { changedModes.append(mode) }
    /// Thrown by `launchAtLoginChanged` (a refused login item).
    var loginError: Error?
    func launchAtLoginChanged(_ enabled: Bool) throws {
        loginToggles.append(enabled)
        if let loginError { throw loginError }
    }
    func mainTabsWindowWillClose() { closeCalls += 1 }
    func setupTabFinished() { setupFinishedCalls += 1; rebootstrapCalls += 1 }
    func openConfig() { openConfigCalls += 1 }
    func resetFinished(scope: ResetScope) { resetFinishedScopes.append(scope) }

    var openConfigCalls = 0
}

/// Shared fixture for the main-window test classes: a window controller on
/// throwaway defaults with a recording delegate, plus view-tree helpers.
/// Not final: the per-tab test classes subclass it.
@MainActor
class MainWindowTestCase: XCTestCase {
    var delegate: RecordingTabsDelegate!
    var window: MainTabsWindowController!
    var fleet: FleetController!
    var updates: UpdateController!
    var fake: FakeFleetServing!
    var suite: UserDefaults!
    var suiteName: String!
    var scratchConfig: URL!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "kinhin-tests.mainwindow-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        delegate = RecordingTabsDelegate()
        scratchConfig = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-mainwindow-\(UUID().uuidString).yaml")
        try? "accounts:\n  - name: github\n    forge: github\n    scope: \"your-org/your-repo\"\nlabels: [a]\n".write(
            to: scratchConfig, atomically: true, encoding: .utf8)
        fake = FakeFleetServing()
        fleet = FleetController()
        fleet.service = fake
        fleet.environment.daemonProbe = { false }  // never touch a real daemon socket
        updates = UpdateController()
        window = MainTabsWindowController(defaults: suite, fleet: fleet, updates: updates)
        window.delegate = delegate
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratchConfig)
        suite.removePersistentDomain(forName: suiteName)
        window = nil
        fleet = nil
        fake = nil
        updates = nil
        delegate = nil
        suite = nil
        suiteName = nil
        try await super.tearDown()
    }

    var tabs: MainTabsModel { window.tabs }
    var models: WindowModels { window.models }

    // MARK: - Helpers

    func waitUntil(_ message: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out: \(message)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Opens the wizard with its forms pointed at a scratch config, so
    /// stepping through never touches (or auto-edits) the real one.
    func showWizard() -> WizardModel {
        tabs.setupIncomplete = true
        tabs.showSetup()
        let wizard = models.wizardModel!
        wizard.mac.configURL = scratchConfig
        wizard.connect.configURL = scratchConfig
        wizard.connect.hasStoredToken = { _ in false }
        wizard.mac.autoEnableLinuxRuntime = false
        return wizard
    }

    /// Helper for test subclasses that need the wizard's token handler to be
    /// hermetic (no Keychain or real config writes).
    func configureWizardTokenHandler(_ hasToken: @escaping @Sendable (ForgeID) -> Bool) {
        models.wizardModel?.connect.hasStoredToken = hasToken
    }

    /// Drives the wizard's Finish → onFinished → dismiss path.
    func finishSetupForTesting() {
        models.wizardModel?.onFinished?()
    }
}
