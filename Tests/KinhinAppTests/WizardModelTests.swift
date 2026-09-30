import XCTest

@testable import kinhin_app

final class WizardModelTests: XCTestCase {
    func testForgeNamesListEveryForgeInOfferOrder() {
        XCTAssertEqual(WizardModel.forgeNames, "GitHub, GitLab, Gitea or Forgejo")
    }
}
