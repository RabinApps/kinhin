import KinhinKit
import XCTest

@testable import kinhin_app

@MainActor
final class WizardModelTests: XCTestCase {
    private func makeWizard() -> WizardModel {
        let model = WizardModel(defaults: UserDefaults(suiteName: "kinhin-wizard-\(UUID().uuidString)") ?? .standard)
        model.mac.autoEnableLinuxRuntime = false
        // Hermetic: forms read a scratch config, never the real one.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-wizard-\(UUID().uuidString).yaml")
        model.mac.configURL = scratch
        model.connect.configURL = scratch
        model.connect.hasStoredToken = { _ in false }
        return model
    }

    nonisolated func testForgeNamesListEveryForgeInOfferOrder() {
        // A locale-aware "or" list: English reads "…, Azure DevOps, or Bitbucket".
        XCTAssertEqual(
            WizardModel.forgeNames,
            ["GitHub", "GitLab", "Gitea", "Forgejo", "Buildkite", "Azure DevOps", "Bitbucket"]
                .formatted(.list(type: .or, width: .standard)))
        XCTAssertTrue(WizardModel.forgeNames.hasPrefix("GitHub, GitLab, Gitea, Forgejo, Buildkite, Azure DevOps"))
    }

    func testThreeStepsEndingInReviewAndStart() {
        XCTAssertEqual(WizardModel.Step.allCases, [.connect, .mac, .review])
        XCTAssertEqual(WizardModel.Step.review.title, "Review & Start")
        let model = makeWizard()
        XCTAssertEqual(model.header, "Step 1 of 3 — Connect your code")
        model.skip()
        model.skip()
        XCTAssertEqual(model.step, .review)
        XCTAssertEqual(model.nextTitle, "Start fleet")
        XCTAssertFalse(model.canSkip, "setup can't be left early")
        XCTAssertFalse(model.tuneItExpanded, "Capacity and Toolchains stay folded away by default")
    }

    func testContinueIsDisabledWhileTheStepHasBlockersAndSaysWhy() {
        let model = makeWizard()
        XCTAssertFalse(model.canContinue)
        XCTAssertEqual(model.currentBlockers.count, 1)
        XCTAssertTrue(model.currentBlockers[0].contains("Connect"))
        model.next()
        XCTAssertEqual(model.step, .connect, "Continue does nothing while blocked; the view shows why instead")
        model.skip()
        XCTAssertEqual(model.step, .mac, "Skip for now still moves on")
    }

    func testMacStepBlocksUntilReadyAndAnImageBeingPreparedCounts() {
        let model = makeWizard()
        model.show(.mac)
        XCTAssertFalse(model.canContinue)
        XCTAssertTrue(model.currentBlockers[0].contains("run jobs on"))

        model.mac.setPreparingImageForTesting(true)
        XCTAssertTrue(model.canContinue, "the image keeps preparing in the background after Start")
        model.mac.setPreparingImageForTesting(false)

        model.mac.setTartReadyForTesting(true)
        XCTAssertTrue(model.canContinue)
    }

    func testReviewBlockersAreEveryOutstandingItem() {
        let model = makeWizard()
        model.show(.review)
        XCTAssertEqual(model.blockers(for: .review), model.missingItems)
        XCTAssertEqual(model.missingItems.count, 2)
        model.mac.setPreparingImageForTesting(true)
        XCTAssertEqual(model.missingItems.count, 1)
        model.refreshSummary()
        XCTAssertTrue(model.summaryText.contains("\(ImagePrepCost.macOSDiskGB) GB"))
        XCTAssertTrue(model.summaryText.contains("background"))
    }

    func testImagePrepCostNoticeStatesDiskAndTimeUpFront() {
        XCTAssertTrue(ImagePrepCost.notice.contains("60 GB"))
        XCTAssertTrue(ImagePrepCost.notice.contains(ImagePrepCost.macOSTimeEstimate))
        XCTAssertTrue(ImagePrepCost.notice.contains("background"))
    }

    func testUntestedBadgeFollowsTheMaturityTable() {
        for forge in ForgeID.allCases {
            XCTAssertEqual(
                MaturityBadge(forge: forge).maturity.isUntested,
                forge != .github && forge != .gitea && forge != .forgejo, forge.rawValue)
        }
        XCTAssertEqual(MaturityBadge(runtime: .appleContainer).maturity, .liveTested)
        XCTAssertEqual(MaturityBadge(runtime: .docker).maturity, .untested)
        XCTAssertEqual(LinuxRuntimeSetup.tartLinux.maturity, .untested)
        XCTAssertEqual(LinuxRuntimeSetup.appleContainer.maturity, .liveTested)
        XCTAssertEqual(Maturity.untested.pickerSuffix, " (untested)")
        XCTAssertEqual(Maturity.liveTested.pickerSuffix, "")
    }
}
