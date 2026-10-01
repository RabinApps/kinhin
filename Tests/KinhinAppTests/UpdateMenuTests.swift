import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class UpdateMenuTests: XCTestCase {
    private var delegate: AppDelegate!
    private var menu: NSMenu!

    override func setUp() async throws {
        try await super.setUp()
        delegate = AppDelegate()
        menu = delegate.buildMenu()
        delegate.menu = menu  // refreshUpdateItems mutates the stored menu
    }

    private var updateItem: NSMenuItem? {
        menu.items.first { $0.identifier?.rawValue == "updateItem" }
    }

    private var versionItem: NSMenuItem? {
        guard let idx = menu.items.firstIndex(where: { $0.identifier?.rawValue == "updateItem" }),
            menu.items.indices.contains(idx + 1)
        else { return nil }
        return menu.items[idx + 1]
    }

    private func makeInfo(version: String = "9.9.9") -> UpdateInfo {
        UpdateInfo(
            tag: "v\(version)",
            version: version,
            dmgName: "kinhin-\(version)-arm64.dmg",
            dmgURL: URL(string: "https://example.com/\(version).dmg")!,
            releaseURL: URL(string: "https://example.com/releases/v\(version)")!,
            publishedAt: Date(),
            notes: "bigger, better, faster"
        )
    }

    // MARK: - menu states

    func testNoPendingUpdateHidesUpdateItem() {
        delegate.updates.pendingUpdate = nil
        delegate.refreshUpdateItems()

        XCTAssertEqual(updateItem?.isHidden, true)
        XCTAssertEqual(versionItem?.title, "  kinhin \(kinhinVersion.current)")
        XCTAssertEqual(versionItem?.isEnabled, false)
    }

    func testPendingUpdateShowsDownloadPromotion() {
        delegate.updates.pendingUpdate = makeInfo()
        delegate.refreshUpdateItems()

        XCTAssertEqual(updateItem?.title, "Update available — kinhin 9.9.9…")
        XCTAssertEqual(updateItem?.isEnabled, true)
        XCTAssertEqual(updateItem?.isHidden, false)
        XCTAssertEqual(versionItem?.title, "  kinhin \(kinhinVersion.current) (up to date)")
        XCTAssertEqual(versionItem?.isEnabled, false)
    }

    func testDownloadingShowsProgressItemUntilFinished() {
        delegate.updates.pendingUpdate = makeInfo()
        delegate.updates.updateCardState = .downloading(name: "kinhin-9.9.9-arm64.dmg")
        delegate.refreshUpdateItems()
        XCTAssertEqual(updateItem?.title, "Downloading kinhin-9.9.9-arm64.dmg…")
        XCTAssertEqual(updateItem?.isEnabled, false)

        delegate.updates.updateCardState = .available(version: "9.9.9")
        delegate.refreshUpdateItems()
        XCTAssertEqual(updateItem?.title, "Update available — kinhin 9.9.9…")
        XCTAssertEqual(updateItem?.isEnabled, true)
    }

    func testPendingUpdateClearsBackToHiddenState() {
        delegate.updates.pendingUpdate = makeInfo()
        delegate.refreshUpdateItems()
        delegate.updates.pendingUpdate = nil
        delegate.refreshUpdateItems()

        XCTAssertEqual(updateItem?.isHidden, true)
        XCTAssertEqual(versionItem?.title, "  kinhin \(kinhinVersion.current)")
    }

    // MARK: - repo selection policy

    func testEnvOverrideWinsWhenWellFormed() {
        XCTAssertEqual(
            UpdatePreferences.repo(fromEnvironment: ["KINHIN_UPDATE_REPO": "fork-RabinApps/kinhin"]),
            "fork-RabinApps/kinhin"
        )
    }

    func testMalformedOrMissingOverrideFallsBackToDefault() {
        XCTAssertEqual(UpdatePreferences.repo(fromEnvironment: [:]), "RabinApps/kinhin")
        XCTAssertEqual(UpdatePreferences.repo(fromEnvironment: ["KINHIN_UPDATE_REPO": ""]), "RabinApps/kinhin")
        XCTAssertEqual(
            UpdatePreferences.repo(fromEnvironment: ["KINHIN_UPDATE_REPO": "just-a-name"]), "RabinApps/kinhin")
        XCTAssertEqual(
            UpdatePreferences.repo(fromEnvironment: ["KINHIN_UPDATE_REPO": "a/b/c"]), "a/b/c",
            "contains a slash — honored as-is")
    }

    func testLegacyOrchardEnvVarStillHonored() {
        XCTAssertEqual(
            UpdatePreferences.repo(fromEnvironment: ["ORCHARD_UPDATE_REPO": "fork-RabinApps/kinhin"]),
            "fork-RabinApps/kinhin",
            "forks configured before the rename must keep updating"
        )
        // The current var wins when both are set.
        XCTAssertEqual(
            UpdatePreferences.repo(fromEnvironment: [
                "KINHIN_UPDATE_REPO": "new-RabinApps/kinhin",
                "ORCHARD_UPDATE_REPO": "old-RabinApps/kinhin",
            ]),
            "new-RabinApps/kinhin"
        )
    }

    // MARK: - last-check persistence

    func testLastCheckRoundTripInScratchDefaults() {
        let suiteName = "kinhin-tests.lastcheck-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertLessThan(UpdatePreferences.lastCheck(in: suite), stamp, "unwritten defaults read as .distantPast")

        UpdatePreferences.setLastCheck(stamp, in: suite)
        XCTAssertEqual(UpdatePreferences.lastCheck(in: suite), stamp, "the 24h throttle stamp must survive a relaunch")
    }
}
