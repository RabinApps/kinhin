import XCTest

@testable import KinhinKit

final class MaturityTableTests: XCTestCase {
    /// The launch forges ran real jobs in the end-to-end suite (docs/e2e-testing.md); Buildkite, Azure DevOps and
    /// Bitbucket are not supported yet.
    func testTheLaunchForgesAreLiveTestedAndTheRestAreNot() {
        let launch: [ForgeID] = [.github, .gitea, .forgejo, .gitlab]
        XCTAssertEqual(Set(ForgeID.allCases.filter { MaturityTable.maturity(of: $0) == .liveTested }), Set(launch))
        for forge in ForgeID.allCases where !launch.contains(forge) {
            let expected: Maturity = forge == .azuredevops ? .experimental : .untested
            XCTAssertEqual(MaturityTable.maturity(of: forge), expected, forge.rawValue)
        }
    }

    /// Azure has run real jobs for a user but not in the project's own lane: experimental, never also live-tested.
    func testExperimentalForgesAreNotAlsoLiveTested() {
        XCTAssertEqual(MaturityTable.experimentalForges, [.azuredevops])
        XCTAssertTrue(Set(MaturityTable.experimentalForges).isDisjoint(with: MaturityTable.liveTestedForges))
    }

    func testEveryRuntimeIsLiveTested() {
        for runtime in RuntimeID.allCases {
            XCTAssertEqual(MaturityTable.maturity(of: runtime), .liveTested, runtime.rawValue)
        }
        XCTAssertEqual(MaturityTable.tartLinux, .liveTested)
    }

    func testEveryRuntimeAndForgeHasAnAnswer() {
        for runtime in RuntimeID.allCases { _ = MaturityTable.maturity(of: runtime) }
        XCTAssertEqual(MaturityTable.liveTestedRuntimes.count, Set(MaturityTable.liveTestedRuntimes).count)
    }
}
