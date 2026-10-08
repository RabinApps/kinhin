import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The wizard's Toolchains step is informational: no seed, no selection, no
/// config writes, and Next works with nothing to validate.
@MainActor final class ToolchainsWizardStepTests: XCTestCase {
    func testStepSitsBetweenCapacityAndStartAndNeedsNoState() {
        XCTAssertEqual(WizardModel.Step.allCases, [.connect, .mac, .capacity, .toolchains, .start])
        XCTAssertEqual(WizardModel.Step.toolchains.title, "Toolchains")
        let model = WizardModel(defaults: UserDefaults(suiteName: "kinhin-tc-wizard-\(UUID().uuidString)") ?? .standard)
        model.show(.toolchains)
        XCTAssertEqual(model.step, .toolchains)
        XCTAssertTrue(model.canContinue, "nothing to validate on this step")
        XCTAssertFalse(model.missingItems.contains { $0.lowercased().contains("toolchain") })
        model.next()
        XCTAssertEqual(model.step, .start)
        XCTAssertFalse(model.summaryText.contains("Toolchains:"), "no selection is summarized")
    }

    func testGuideExamplesAreValidAndMentionBothWaysToDeclare() throws {
        let text = ToolchainsGuide.intro
        XCTAssertTrue(
            text.contains(".kinhin.yml") && text.contains("repo_file: true") && text.contains("projects[].toolchains"))
        XCTAssertTrue(ToolchainsGuide.noToolchainsNote.contains("kinhin-toolchain install"))
        XCTAssertEqual(ToolchainsGuide.docsURL?.fragment, "per-project-toolchains")

        let repoFile = try XCTUnwrap(ToolchainsGuide.examples.first { $0.yaml.hasPrefix("toolchains:") })
        XCTAssertNotNil(try ProjectFileLoader.parse(Data(repoFile.yaml.utf8)))

        let base =
            "accounts:\n  - name: github\n    forge: github\n    scope: \"acme/widgets\"\nlabels: [self-hosted]\n"
        for example in ToolchainsGuide.examples where example.yaml.hasPrefix("projects:") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "kinhin-guide-\(UUID().uuidString).yaml")
            defer { try? FileManager.default.removeItem(at: url) }
            try (base + example.yaml).write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(try ConfigLoader.load(from: url).projects.count, 1, example.title)
        }
    }
}
