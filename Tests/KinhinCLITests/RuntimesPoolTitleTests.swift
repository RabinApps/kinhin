import XCTest

@testable import KinhinKit
@testable import kinhin

// `kinhin runtimes` once titled every non-Tart pool "Apple containers (Linux)", so a Docker or host pool printed
// as the wrong runtime (found by the e2e suite's host lane). Each runtime must keep its own title, matching the app.
final class RuntimesPoolTitleTests: XCTestCase {
    func testEveryRuntimeHasItsOwnTitle() {
        let titles = RuntimeID.allCases.map(RuntimesCommand.poolTitle)
        XCTAssertEqual(Set(titles).count, RuntimeID.allCases.count, "\(titles)")
        XCTAssertEqual(RuntimesCommand.poolTitle(.docker), "🐳 Docker (Linux)")
        XCTAssertEqual(RuntimesCommand.poolTitle(.host), "🖥 Host (this Mac)")
    }
}
