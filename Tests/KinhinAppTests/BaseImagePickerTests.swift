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

    // MARK: the choices

    func testDefaultIsUbuntuAndCuratedValuesMapToTheirEntries() {
        XCTAssertEqual(BaseImageChoice.title(at: BaseImageChoice.index(of: nil)), "Ubuntu 24.04 (default)")
        XCTAssertEqual(BaseImageChoice.title(at: BaseImageChoice.index(of: "debian:12")), "Debian 12")
        XCTAssertEqual(BaseImageChoice.index(of: "ghcr.io/acme/base:1"), BaseImageChoice.otherIndex)
        XCTAssertEqual(BaseImageChoice.title(at: BaseImageChoice.otherIndex), "Other…")
    }

    func testTheDefaultIsStoredAsNoKey() {
        XCTAssertNil(BaseImageChoice.stored(LinuxBaseImage.defaultReference))
        XCTAssertEqual(BaseImageChoice.stored("debian:12"), "debian:12")
    }

    func testCustomEntryIsValidatedBeforeItIsUsed() {
        for bad in ["--privileged", "two words", ""] {
            guard case .failure(let issue) = BaseImageChoice.validate(bad) else {
                return XCTFail("\"\(bad)\" should be rejected")
            }
            XCTAssertTrue(issue.text.hasPrefix("Base image"), issue.text)
        }
        XCTAssertEqual(try BaseImageChoice.validate("  debian:bookworm-slim ").get(), "debian:bookworm-slim")
    }

    // MARK: Toolchains page

    func testToolchainsPageOffersAPickerForEachLinuxRuntimeAndSavesIt() throws {
        let model = ToolchainsModel()
        model.configURL = configURL
        model.reload()
        XCTAssertEqual(
            Set(model.imageRuntimes.map(\.runtime).filter { $0 != .tart }), [.appleContainer, .docker])

        var edited = 0
        model.onEdited = { edited += 1 }
        model.saveBaseImage("debian:12", for: .docker)
        XCTAssertEqual(try saved(.docker), "debian:12")
        XCTAssertNil(try saved(.appleContainer), "the other runtime is untouched")
        XCTAssertEqual(edited, 1)
    }

    func testToolchainsPageRevertsThePickerWhenTheSaveFails() throws {
        let model = ToolchainsModel()
        model.configURL = configURL
        model.reload()
        // Remove the docker section behind the page's back so the save is refused.
        try "repo: \"acme/widgets\"\nlabels: [self-hosted]\ncontainer:\n  image: \"kinhin-ci-linux\"\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        model.saveBaseImage("debian:12", for: .docker)
        XCTAssertEqual(alerts, 1, "the failure is shown")
        XCTAssertNil(model.baseImage(for: .docker), "the page shows what is actually saved")
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
