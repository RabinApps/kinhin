import Sparkle
import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The card's state machine, driven through the same callbacks Sparkle makes.
/// The updater is never started, so nothing reaches the network or shows a prompt.
@MainActor
final class UpdateControllerTests: XCTestCase {
    private var updates: UpdateController!

    override func setUp() async throws {
        try await super.setUp()
        updates = UpdateController()
    }

    override func tearDown() async throws {
        updates = nil
        try await super.tearDown()
    }

    private func sparkleError(_ code: Int) -> NSError {
        NSError(domain: SUSparkleErrorDomain, code: code)
    }

    func testStartsIdleWithoutAPendingUpdate() {
        guard case .idle = updates.updateCardState else { return XCTFail("\(updates.updateCardState)") }
        XCTAssertNil(updates.pendingVersion)
    }

    func testFoundReleaseIsOfferedWhenTheCycleEnds() {
        updates.handleFoundUpdate(version: "9.9.9")
        updates.handleCycleFinished(error: nil)

        XCTAssertEqual(updates.updateCardState, .available(version: "9.9.9"))
        XCTAssertEqual(updates.pendingVersion, "9.9.9")
    }

    func testNoReleaseClearsAPendingUpdate() {
        updates.handleFoundUpdate(version: "9.9.9")
        updates.handleNoUpdate()
        updates.handleCycleFinished(error: sparkleError(1001))  // SUNoUpdateError is not a failure

        XCTAssertNil(updates.pendingVersion, "a superseded update is dropped")
        guard case .upToDate = updates.updateCardState else { return XCTFail("\(updates.updateCardState)") }
    }

    func testAFailedCheckShowsTheReasonAndKeepsAKnownUpdate() {
        updates.handleFoundUpdate(version: "9.9.9")
        updates.handleCycleFinished(
            error: NSError(
                domain: "network", code: -1009,
                userInfo: [
                    NSLocalizedDescriptionKey: "offline"
                ]))

        XCTAssertEqual(updates.updateCardState, .failed("offline"))
        XCTAssertEqual(updates.pendingVersion, "9.9.9", "a transient failure doesn't forget a known update")
    }

    func testADeclinedInstallStaysOffered() {
        updates.handleFoundUpdate(version: "9.9.9")
        updates.handleCycleFinished(error: sparkleError(4007))  // SUInstallationCanceledError

        XCTAssertEqual(updates.updateCardState, .available(version: "9.9.9"))
    }

    func testARejectedCheckDoesNotLeaveTheCardChecking() {
        updates.canStartCheck = { false }  // Sparkle ignores the request and sends no cycle callback
        updates.checkForUpdates()

        XCTAssertNotEqual(updates.updateCardState, .checking, "a check Sparkle never starts must not stick")
    }

    func testOnlySparkleNoUpdateAndCancelledInstallAreBenign() {
        XCTAssertTrue(UpdateController.isBenign(sparkleError(1001)))
        XCTAssertTrue(UpdateController.isBenign(sparkleError(4007)))
        XCTAssertFalse(UpdateController.isBenign(sparkleError(1)))
        XCTAssertFalse(UpdateController.isBenign(NSError(domain: "network", code: 1001)), "same code, other domain")
    }
}
