import XCTest

@testable import kinhin_app

final class WizardModelTests: XCTestCase {
    func testForgeNamesListEveryForgeInOfferOrder() {
        XCTAssertEqual(
            WizardModel.forgeNames, "GitHub, GitLab, Gitea, Forgejo, Buildkite, Azure DevOps or Bitbucket")
    }

    @MainActor func testCapacityStepFollowsMacAndNeedsNoStateToContinue() {
        let model = WizardModel(
            defaults: UserDefaults(suiteName: "kinhin-cap-wizard-\(UUID().uuidString)") ?? .standard)
        XCTAssertEqual(WizardModel.Step.capacity.title, "Split your capacity")
        model.show(.mac)
        model.next()
        XCTAssertEqual(model.step, .capacity)
        XCTAssertTrue(model.canSkip)
        XCTAssertTrue(model.canContinue, "the split is optional; defaults are valid")
        XCTAssertEqual(model.header, "Step 3 of 5 — Split your capacity")
        model.back()
        XCTAssertEqual(model.step, .mac)
    }
}
