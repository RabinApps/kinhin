import AppKit
import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class BaseImagePickerTests: XCTestCase {
    private var configURL: URL!
    private var alerts = 0

    override func setUpWithError() throws {
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-bip-\(UUID().uuidString).yaml")
        try """
        repo: "acme/widgets"
        labels: [self-hosted]
        container:
          image: "kinhin-ci-linux"
        docker:
          image: "kinhin-ci-linux"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        AlertKit.runModal = { [unowned self] _ in
            alerts += 1
            return .alertFirstButtonReturn
        }
    }

    override func tearDown() async throws {
        AlertKit.runModal = { $0.runModal() }
        try? FileManager.default.removeItem(at: configURL)
    }

    private func saved(_ runtime: RuntimeID) throws -> String? {
        try ConfigLoader.load(from: configURL).baseImageForTesting(runtime)
    }

    // MARK: the control

    func testDefaultShowsUbuntuAndHidesTheCustomField() {
        let picker = BaseImagePicker(value: nil)
        XCTAssertEqual(picker.popup.titleOfSelectedItem, "Ubuntu 24.04 (default)")
        XCTAssertTrue(picker.field.isHidden)
        XCTAssertNil(picker.value)
    }

    func testCuratedAndCustomValuesSelectTheRightControl() {
        let debian = BaseImagePicker(value: "debian:12")
        XCTAssertEqual(debian.popup.titleOfSelectedItem, "Debian 12")
        XCTAssertTrue(debian.field.isHidden)

        let custom = BaseImagePicker(value: "ghcr.io/acme/base:1")
        XCTAssertEqual(custom.popup.titleOfSelectedItem, "Other…")
        XCTAssertFalse(custom.field.isHidden)
        XCTAssertEqual(custom.field.stringValue, "ghcr.io/acme/base:1")
    }

    func testPickingACuratedImageReportsItAndTheDefaultReportsNil() {
        let picker = BaseImagePicker(value: nil)
        var reported: [String?] = []
        picker.onChange = { reported.append($0) }
        picker.popup.selectItem(withTitle: "Debian 12")
        _ = picker.popup.target?.perform(picker.popup.action, with: picker.popup)
        XCTAssertEqual(reported, ["debian:12"])

        picker.popup.selectItem(withTitle: "Ubuntu 24.04 (default)")
        _ = picker.popup.target?.perform(picker.popup.action, with: picker.popup)
        XCTAssertEqual(reported, ["debian:12", nil], "the default is stored as no key")
    }

    func testCustomEntryIsValidatedBeforeItIsReported() {
        let picker = BaseImagePicker(value: nil)
        var reported: [String?] = []
        picker.onChange = { reported.append($0) }

        picker.commitCustom("--privileged")
        picker.commitCustom("two words")
        picker.commitCustom("")
        XCTAssertTrue(reported.isEmpty, "unusable references are never reported")
        XCTAssertFalse(picker.problemLabel.isHidden)

        picker.commitCustom("  debian:bookworm-slim ")
        XCTAssertEqual(reported, ["debian:bookworm-slim"])
        XCTAssertTrue(picker.problemLabel.isHidden)
    }

    func testSetValueDoesNotReportAChange() {
        let picker = BaseImagePicker(value: nil)
        var reported = 0
        picker.onChange = { _ in reported += 1 }
        picker.setValue("debian:12")
        XCTAssertEqual(reported, 0)
        XCTAssertEqual(picker.value, "debian:12")
    }

    // MARK: Toolchains page

    func testToolchainsPageOffersAPickerForEachLinuxRuntimeAndSavesIt() throws {
        let vc = ToolchainsViewController()
        vc.configURL = configURL
        _ = vc.view
        XCTAssertEqual(Set(vc.baseImagePickers.keys), [.appleContainer, .docker])

        var edited = 0
        vc.onEdited = { edited += 1 }
        vc.baseImagePickers[.docker]?.commitCustom("debian:12")
        XCTAssertEqual(try saved(.docker), "debian:12")
        XCTAssertNil(try saved(.appleContainer), "the other runtime is untouched")
        XCTAssertEqual(edited, 1)
    }

    func testToolchainsPageRevertsThePickerWhenTheSaveFails() throws {
        let vc = ToolchainsViewController()
        vc.configURL = configURL
        _ = vc.view
        // Remove the docker section behind the page's back so the save is refused.
        try "repo: \"acme/widgets\"\nlabels: [self-hosted]\ncontainer:\n  image: \"kinhin-ci-linux\"\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        vc.baseImagePickers[.docker]?.commitCustom("debian:12")
        XCTAssertEqual(alerts, 1, "the failure is shown")
        XCTAssertNil(vc.baseImagePickers[.docker]?.value, "the picker shows what is actually saved")
    }

    // MARK: Mac tools form

    func testMacToolsFormShowsThePickerOnlyWhileTheRuntimeIsEnabled() throws {
        let form = MacToolsFormViewController()
        form.configURL = configURL
        _ = form.view
        XCTAssertTrue(form.model.containerOn, "the picker is shown while the runtime is enabled")
        form.model.saveBaseImage("debian:12", for: .appleContainer)
        XCTAssertEqual(try saved(.appleContainer), "debian:12")
        XCTAssertEqual(form.model.containerBaseImage, "debian:12")

        form.setContainerForTesting(false)
        XCTAssertFalse(form.model.containerOn, "hidden once the runtime is off")
        form.setContainerForTesting(true)
        XCTAssertEqual(form.model.containerBaseImage, nil, "a re-enabled section starts from the saved default")
    }
}

extension KinhinConfig {
    fileprivate func baseImageForTesting(_ runtime: RuntimeID) -> String? {
        runtime == .docker ? docker?.baseImage : container?.baseImage
    }
}
