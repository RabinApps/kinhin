import AppKit
import SwiftUI
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Records MainTabsWindowDelegate calls so window actions can be tested
/// without touching a real engine, daemon, or NSApp.terminate.
@MainActor
final class RecordingTabsDelegate: MainTabsWindowDelegate {
    var startCalls = 0
    var stopCalls = 0
    var pauseCalls = 0
    var resumeCalls = 0
    var deletedVMIDs: [String] = []
    var logsCalls = 0
    var updateCalls = 0
    var changedModes: [LaunchMode] = []
    var loginToggles: [Bool] = []
    var closeCalls = 0
    var setupFinishedCalls = 0
    var rebootstrapCalls = 0

    func startFleet() { startCalls += 1 }
    func stopFleet() { stopCalls += 1 }
    func pauseFleet() { pauseCalls += 1 }
    func resumeFleet() { resumeCalls += 1 }
    func deleteVM(id: String) { deletedVMIDs.append(id) }
    func openLogsFolder() { logsCalls += 1 }
    func checkForUpdatesNow() { updateCalls += 1 }
    func launchModeChanged(_ mode: LaunchMode) { changedModes.append(mode) }
    func launchAtLoginChanged(_ enabled: Bool) { loginToggles.append(enabled) }
    func mainTabsWindowWillClose() { closeCalls += 1 }
    func setupTabFinished() { setupFinishedCalls += 1; rebootstrapCalls += 1 }
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
        fleet = FleetController()
        updates = UpdateController()
        window = MainTabsWindowController(defaults: suite, fleet: fleet, updates: updates)
        window.delegate = delegate
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratchConfig)
        suite.removePersistentDomain(forName: suiteName)
        window = nil
        fleet = nil
        updates = nil
        delegate = nil
        suite = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Opens the wizard with its forms pointed at a scratch config, so
    /// stepping through never touches (or auto-edits) the real one.
    func showWizard() -> WizardModel {
        window.setupIncompleteFlag = true
        window.showSetup()
        let wizard = window.wizardModel!
        wizard.mac.configURL = scratchConfig
        wizard.connect.configURL = scratchConfig
        wizard.connect.hasStoredToken = { _ in false }
        wizard.mac.autoEnableLinuxRuntime = false
        return wizard
    }

    func segment() -> NSSegmentedControl {
        guard let control = window.window?.contentView?.flattenedViews().compactMap({ $0 as? NSSegmentedControl }).first
        else {
            fatalError("main window must carry the tab segment control")
        }
        return control
    }

    func index(of tab: MainTab) -> Int {
        window.visibleTabs.firstIndex(of: tab) ?? -1
    }

    /// Drives the wizard's Finish → onFinished → dismiss path.
    func finishSetupForTesting() {
        window.wizardModel?.onFinished?()
    }

    func allText() -> String {
        window.window?.contentView?.flattenedText().joined(separator: "\n") ?? ""
    }

    /// Realizes the window's layout and reports whether every hosting view's
    /// primary SwiftUI child has real geometry. SwiftUI renders lazily and an
    /// empty form collapses to a zero-width column, so a section whose model
    /// never loaded still passes an "is the right view installed" check —
    /// this is the geometry-level signal that catches it.
    func contentHasVisibleArea(in controller: MainTabsWindowController, line: UInt = #line) -> Bool {
        guard let content = controller.window?.contentView else {
            XCTFail("the window has no content view", line: line)
            return false
        }
        content.layoutSubtreeIfNeeded()
        // NSHostingView is generic, so `is NSHostingView<…>` can't typecheck;
        // match the runtime type name instead.
        let hosted = content.flattenedViews().filter { host in
            String(describing: type(of: host)).hasPrefix("NSHostingView<")
        }
        guard !hosted.isEmpty else {
            XCTFail("no hosting view found in the content view", line: line)
            return false
        }
        // The hosting view's FIRST child is its SwiftUI content container
        // (zero-sized when the form is empty); the others are focus rings and
        // other AppKit chrome that keep their size regardless.
        return hosted.allSatisfy { host in
            guard let contentChild = host.subviews.first else { return false }
            let frame = contentChild.convert(contentChild.bounds, to: nil)
            return !frame.isEmpty && frame.width > 1 && frame.height > 1
        }
    }

    /// Fires a control's action the way a click would (target/action ignores
    /// method visibility, so private @objc actions stay reachable in tests).
    /// Named `fire` to stay clear of NSObject.perform(_:).
    func fire(_ control: NSControl?, line: UInt = #line) {
        guard let control else { return XCTFail("control is nil", line: line) }
        guard let target = control.target else {
            return XCTFail("control has no target", line: line)
        }
        guard let action = control.action else {
            return XCTFail("control has no action", line: line)
        }
        _ = target.perform(action, with: control)
    }
}

extension NSView {
    /// All descendant views, depth-first.
    func flattenedViews() -> [NSView] {
        var result: [NSView] = []
        for sub in subviews {
            result.append(sub)
            result.append(contentsOf: sub.flattenedViews())
        }
        return result
    }

    func flattenedText() -> [String] {
        flattenedViews().compactMap { ($0 as? NSTextField)?.stringValue }
    }

    func flattenedButtons() -> [NSButton] {
        flattenedViews().compactMap { $0 as? NSButton }
    }
}
