import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class VMEntityQueryTests: XCTestCase {
    private let productionBridge: FleetIntentBridge = AppFleetIntentBridge()

    override func tearDown() async throws {
        // The bridge is a static: restoring the previous test's fake would
        // chain stale fakes across tests — always restore production.
        FleetIntentEnvironment.bridge = productionBridge
        try await super.tearDown()
    }

    @discardableResult
    private func makeBridge(_ ids: [String]) -> FakeFleetIntentBridge {
        let records = ids.map { VMRecord(id: $0, phase: .busy) }
        let bridge = FakeFleetIntentBridge(FleetStatus(running: true, records: records))
        FleetIntentEnvironment.bridge = bridge
        return bridge
    }

    func testSuggestedEntitiesMirrorTheFleet() async throws {
        makeBridge(["vm-1", "vm-2"])
        let suggestions = try await VMEntityQuery().suggestedEntities()
        XCTAssertEqual(suggestions.map(\.id), ["vm-1", "vm-2"])
        XCTAssertEqual(suggestions.map(\.phase), ["busy", "busy"], "phases surface in the picker")
    }

    func testEntityResolutionFiltersToRequestedIDs() async throws {
        makeBridge(["vm-1", "vm-2"])
        // A saved shortcut can point at a VM that has since been deleted;
        // revalidation must drop it rather than fail the whole shortcut.
        let resolved = try await VMEntityQuery().entities(for: ["vm-2", "gone"])
        XCTAssertEqual(resolved.map(\.id), ["vm-2"])
    }
}
