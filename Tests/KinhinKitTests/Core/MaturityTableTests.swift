import XCTest

@testable import KinhinKit

final class MaturityTableTests: XCTestCase {
    func testOnlyGitHubIsLiveTestedAmongForges() {
        XCTAssertEqual(ForgeID.allCases.filter { MaturityTable.maturity(of: $0) == .liveTested }, [.github])
        for forge in ForgeID.allCases where forge != .github {
            XCTAssertTrue(MaturityTable.maturity(of: forge).isUntested, forge.rawValue)
        }
    }

    func testTartMacOSAndAppleContainerAreLiveTestedAndTheRestAreNot() {
        XCTAssertEqual(MaturityTable.maturity(of: .tart), .liveTested)
        XCTAssertEqual(MaturityTable.maturity(of: .appleContainer), .liveTested)
        XCTAssertEqual(MaturityTable.maturity(of: .docker), .untested)
        XCTAssertEqual(MaturityTable.maturity(of: .host), .untested)
        XCTAssertEqual(MaturityTable.tartLinux, .untested, "Tart serving Linux VMs is a separate, untested path")
    }

    func testEveryRuntimeAndForgeHasAnAnswer() {
        for runtime in RuntimeID.allCases { _ = MaturityTable.maturity(of: runtime) }
        XCTAssertEqual(MaturityTable.liveTestedRuntimes.count, Set(MaturityTable.liveTestedRuntimes).count)
    }
}
