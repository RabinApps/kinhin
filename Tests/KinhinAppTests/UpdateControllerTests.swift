import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class UpdateControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var updates: UpdateController!
    private var fake: FakeUpdateChecker!
    private var opened: [URL] = []
    private var openSucceeds = true

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "kinhin-tests.updates-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        fake = FakeUpdateChecker()
        updates = UpdateController(defaults: defaults)
        updates.makeChecker = { [fake] in fake! }
        updates.open = { [unowned self] in
            opened.append($0)
            return openSucceeds
        }
    }

    override func tearDown() async throws {
        updates.cancelAll()
        defaults.removePersistentDomain(forName: suiteName)
        updates = nil
        try await super.tearDown()
    }

    private func info(_ version: String = "9.9.9") -> UpdateInfo {
        UpdateInfo(
            tag: "v\(version)", version: version, dmgName: "kinhin-\(version)-arm64.dmg",
            dmgURL: URL(string: "https://example.com/\(version).dmg")!,
            releaseURL: URL(string: "https://example.com/r/\(version)")!, publishedAt: nil, notes: nil)
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out: \(message)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func settled() -> Bool {
        switch updates.updateCardState {
        case .checking, .downloading: return false
        default: return true
        }
    }

    // MARK: - Checking

    func testAvailableReleaseIsRememberedAndStampsTheThrottle() async {
        fake.checkResult = .success(.available(info()))
        updates.checkForUpdates()
        XCTAssertEqual(updates.updateCardState, .checking)
        await waitUntil("check finishes") { settled() }

        XCTAssertEqual(updates.updateCardState, .available(version: "9.9.9"))
        XCTAssertEqual(updates.pendingUpdate?.tag, "v9.9.9")
        XCTAssertGreaterThan(UpdatePreferences.lastCheck(in: defaults), .distantPast, "the 24h stamp is written")
    }

    func testUpToDateClearsAPendingUpdate() async {
        updates.pendingUpdate = info()
        fake.checkResult = .success(.upToDate)
        updates.checkForUpdates()
        await waitUntil("check finishes") { settled() }

        guard case .upToDate = updates.updateCardState else { return XCTFail("\(updates.updateCardState)") }
        XCTAssertNil(updates.pendingUpdate, "a superseded update is dropped")
    }

    func testFailedCheckShowsTheReasonAndKeepsAPendingUpdate() async {
        updates.pendingUpdate = info()
        fake.checkResult = .failure(UpdateCheckError.notFound("RabinApps/kinhin"))
        updates.checkForUpdates()
        await waitUntil("check finishes") { settled() }

        XCTAssertEqual(
            updates.updateCardState, .failed(UpdateCheckError.notFound("RabinApps/kinhin").localizedDescription))
        XCTAssertNotNil(updates.pendingUpdate, "a transient failure doesn't forget a known update")
        XCTAssertEqual(UpdatePreferences.lastCheck(in: defaults), .distantPast, "a failed check isn't stamped")
    }

    func testCancelledCheckReturnsToIdle() async {
        fake.checkResult = .failure(CancellationError())
        updates.checkForUpdates()
        await waitUntil("check finishes") { settled() }
        guard case .idle = updates.updateCardState else { return XCTFail("\(updates.updateCardState)") }
    }

    func testOnlyOneCheckRunsAtATime() async {
        fake.gated = true
        updates.checkForUpdates()
        await waitUntil("check starts") { fake.checks == 1 }
        updates.checkForUpdates()
        updates.checkForUpdates()
        XCTAssertEqual(fake.checks, 1, "a second request while one runs is ignored")

        fake.releaseGate()
        await waitUntil("check finishes") { settled() }
        updates.checkForUpdates()
        await waitUntil("a later check runs") { fake.checks == 2 }
        await waitUntil("settles") { settled() }
    }

    // MARK: - Download

    func testCheckOrDownloadChecksWhenNothingIsWaiting() async {
        updates.checkOrDownload()
        await waitUntil("check") { fake.checks == 1 }
        await waitUntil("settles") { settled() }
        XCTAssertTrue(fake.downloads.isEmpty)
    }

    func testCheckOrDownloadDownloadsAndOpensTheDMG() async {
        updates.pendingUpdate = info()
        updates.checkOrDownload()
        await waitUntil("download") { fake.downloads == ["v9.9.9"] }
        await waitUntil("settles") { settled() }

        XCTAssertEqual(opened, [URL(fileURLWithPath: "/tmp/kinhin-test.dmg")])
        XCTAssertEqual(updates.updateCardState, .available(version: "9.9.9"), "the update stays offered")
    }

    func testAFinderOpenFailureIsShownWithTheFilePath() async {
        updates.pendingUpdate = info()
        openSucceeds = false
        updates.checkOrDownload()
        await waitUntil("settles") { settled() && !fake.downloads.isEmpty }
        guard case .failed(let message) = updates.updateCardState else { return XCTFail("\(updates.updateCardState)") }
        XCTAssertTrue(message.contains("/tmp/kinhin-test.dmg"), message)
    }

    func testFailedDownloadShowsTheReasonAndOpensNothing() async {
        updates.pendingUpdate = info()
        fake.downloadResult = .failure(UpdateCheckError.checksumMismatch("kinhin-9.9.9-arm64.dmg"))
        updates.checkOrDownload()
        await waitUntil("settles") { settled() && !fake.downloads.isEmpty }

        XCTAssertTrue(opened.isEmpty, "an unverified DMG is never opened")
        guard case .failed(let message) = updates.updateCardState else { return XCTFail("\(updates.updateCardState)") }
        XCTAssertFalse(message.isEmpty)
    }

    func testCancelledDownloadKeepsTheUpdateOffered() async {
        updates.pendingUpdate = info()
        fake.downloadResult = .failure(CancellationError())
        updates.checkOrDownload()
        await waitUntil("settles") { settled() && !fake.downloads.isEmpty }
        XCTAssertEqual(updates.updateCardState, .available(version: "9.9.9"))
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: - Scheduling

    func testScheduledChecksSkipTheLaunchCheckWhenOneRanRecently() async {
        UpdatePreferences.setLastCheck(Date(), in: defaults)
        updates.startScheduledChecks()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fake.checks, 0, "within the 24h throttle there's no automatic check")
    }

    func testScheduledChecksRunAtLaunchWhenTheLastCheckIsStale() async {
        UpdatePreferences.setLastCheck(Date().addingTimeInterval(-2 * UpdatePreferences.interval), in: defaults)
        updates.startScheduledChecks()
        await waitUntil("launch check") { fake.checks == 1 }
        await waitUntil("settles") { settled() }
    }
}
