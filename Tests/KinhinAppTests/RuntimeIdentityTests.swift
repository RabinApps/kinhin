import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// `RuntimeIdentity`: the one place a runtime's title, mark and tint live.
@MainActor
final class RuntimeIdentityTests: XCTestCase {
    func testEveryRuntimeHasAMarkATitleAndADistinctTint() {
        for runtime in RuntimeID.allCases {
            let identity = runtime.identity
            XCTAssertFalse(identity.mark.isEmpty)
            XCTAssertFalse(identity.title.isEmpty)
            XCTAssertEqual(identity.markedTitle, "\(identity.mark) \(identity.title)")
        }
        XCTAssertEqual(Set(RuntimeID.allCases.map(\.identity.mark)).count, RuntimeID.allCases.count)
        XCTAssertEqual(Set(RuntimeID.allCases.map { "\($0.identity.tint)" }).count, RuntimeID.allCases.count)
    }

    func testTitlesMatchTheDesign() {
        XCTAssertEqual(RuntimeID.tart.identity.title, "Tart VMs (macOS)")
        XCTAssertEqual(RuntimeID.appleContainer.identity.title, "Apple containers (Linux)")
        XCTAssertEqual(RuntimeID.docker.identity.title, "Docker (Linux)")
        XCTAssertEqual(RuntimeID.host.identity.title, "Host (this Mac)", "the Host is part of the same source")
    }

    func testTheFleetLanesAndTheRoutingPoolsReadTheSameIdentity() {
        let lanes = FleetDiagramModel(status: FleetStatus(records: [])).lanes
        for lane in lanes {
            XCTAssertEqual(lane.title, lane.id.identity.title)
            XCTAssertEqual(lane.mark, lane.id.identity.mark)
        }
        for runtime in RuntimeID.allCases {
            XCTAssertEqual(RuntimesModel.runtimeTitle(runtime), runtime.identity.choiceTitle)
        }
    }
}
