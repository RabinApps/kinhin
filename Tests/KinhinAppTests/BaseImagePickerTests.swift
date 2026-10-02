import AppKit
import Synchronization
import XCTest

@testable import KinhinKit
@testable import kinhin_app

@MainActor
final class BaseImagePickerTests: XCTestCase {
    private var configURL: URL!
    private var alerts = 0

    override func setUp() async throws {
        try await super.setUp()
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-bip-\(UUID().uuidString).yaml")
        try """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
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

    // MARK: - the choices

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

    // MARK: - the tart VM catalog

    /// A resolver that answers with a fixed digest and records its inputs.
    private final class FakeResolver: DigestResolving {
        let digest: String
        private let asked = Mutex<[String]>([])
        private let thrown: (any Error & Sendable)?

        init(digest: String = "sha256:\(String(repeating: "ab", count: 32))", thrown: (any Error & Sendable)? = nil) {
            self.digest = digest
            self.thrown = thrown
        }

        var askedReferences: [String] { asked.withLock { $0 } }

        func resolveDigest(_ reference: String) async throws -> String {
            asked.withLock { $0.append(reference) }
            if let thrown { throw thrown }
            return digest
        }
    }

    private static let reference = "ghcr.io/cirruslabs/macos-sequoia-base:latest"

    func testPinResolvesTheReferenceAndReturnsThePinnedForm() async {
        let resolver = FakeResolver()
        let outcome = await BaseImageChoice.pin(Self.reference, in: .tartVM, resolver: resolver)
        XCTAssertEqual(resolver.askedReferences, [Self.reference], "the typed reference is what gets resolved")
        guard case .success(let pin) = outcome else { return XCTFail("expected success: \(outcome)") }
        XCTAssertTrue(pin.pinned)
        XCTAssertEqual(pin.reference, "\(Self.reference)@\(resolver.digest)")
        XCTAssertTrue(pin.message.contains(resolver.digest), pin.message)
    }

    func testPinSurfacesRegistryFailuresAsProblemText() async {
        let resolver = FakeResolver(
            thrown: ImageError.malformedVersionFeed(feed: Self.reference, reason: "registry answered HTTP 404"))
        let outcome = await BaseImageChoice.pin(Self.reference, in: .tartVM, resolver: resolver)
        guard case .failure(let issue) = outcome else { return XCTFail("expected failure: \(outcome)") }
        XCTAssertTrue(issue.text.contains("404"), issue.text)
    }

    func testPinRejectsUnusableReferencesWithoutTouchingTheRegistry() async {
        let resolver = FakeResolver()
        for bad in ["", "two words", "--privileged", "ghcr.io/acme/image@sha256:short"] {
            let outcome = await BaseImageChoice.pin(bad, in: .tartVM, resolver: resolver)
            guard case .failure = outcome else { return XCTFail("'\(bad)' should be rejected") }
        }
        XCTAssertTrue(resolver.askedReferences.isEmpty, "a rejected reference must not reach the registry")
    }

    func testPinIsTartOnly() async {
        let resolver = FakeResolver()
        let outcome = await BaseImageChoice.pin("debian:12", in: .linuxContainer, resolver: resolver)
        guard case .failure(let issue) = outcome else { return XCTFail("expected the tart-only refusal") }
        XCTAssertTrue(issue.text.contains("tart"), issue.text)
        XCTAssertTrue(resolver.askedReferences.isEmpty)
    }

    func testSavingAResolvedPinWritesThePinnedReferenceToTheConfig() throws {
        // What the picker stores after a successful Pin… is the digest-pinned
        // form; it must survive the save path's validation (TartBaseImage
        // problem checking) and the config round trip intact.
        let pinned = "\(Self.reference)@sha256:\(String(repeating: "cd", count: 32))"
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()

        model.saveBaseImage(pinned, for: .tart)
        XCTAssertEqual(try saved(.tart), pinned)
    }

    func testTartCatalogMapsCuratedReferencesAndDefaultsToNoKey() {
        let catalog = BaseImageChoice.Catalog.tartVM
        let sequoia = "ghcr.io/cirruslabs/macos-sequoia-base:latest"
        XCTAssertTrue(catalog.entries.contains { $0.reference == sequoia })
        XCTAssertEqual(
            BaseImageChoice.index(of: sequoia, in: catalog), catalog.entries.firstIndex { $0.reference == sequoia })
        XCTAssertEqual(
            BaseImageChoice.index(of: "ghcr.io/acme/custom:1", in: catalog),
            catalog.entries.count,
            "an unknown reference is Other…")
        XCTAssertNil(BaseImageChoice.stored(TartBaseImage.defaultReference, in: catalog), "default = no key")
        XCTAssertEqual(BaseImageChoice.stored(sequoia, in: catalog), sequoia)
        XCTAssertThrowsError(try BaseImageChoice.validate("--privileged", in: catalog).get())
    }

    func testSavingATartBaseImageWritesTheConfigKeyAndClearsIt() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()

        model.saveBaseImage("ghcr.io/cirruslabs/macos-sequoia-base:latest", for: .tart)
        XCTAssertEqual(try saved(.tart), "ghcr.io/cirruslabs/macos-sequoia-base:latest")

        model.saveBaseImage(nil, for: .tart)
        XCTAssertNil(try saved(.tart), "the default clears the key")
    }

    // MARK: - Tart (Linux VM)

    func testTartLinuxCatalogStoresEveryChoiceExplicitly() {
        let catalog = BaseImageChoice.Catalog.tartLinux
        XCTAssertTrue(catalog.entries.allSatisfy { !$0.reference.contains("macos-") }, "Linux images only")
        XCTAssertEqual(
            BaseImageChoice.stored(TartBaseImage.defaultLinuxReference, in: catalog),
            TartBaseImage.defaultLinuxReference, "unset would mean the macOS image, so Ubuntu must be stored")
        XCTAssertFalse(BaseImageChoice.title(at: 0, in: catalog).contains("(default)"))
    }

    func testTartLinuxCheckboxWritesAndClearsTheBaseImage() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        model.setTartInstalledForTesting(true)

        model.setTartLinux(true)
        XCTAssertEqual(try saved(.tart), TartBaseImage.defaultLinuxReference)
        XCTAssertTrue(model.tartLinuxOn)

        model.setTartLinux(false)
        XCTAssertNil(try saved(.tart), "off returns tart to the macOS default")
        XCTAssertFalse(model.tartLinuxOn)
    }

    func testTartLinuxCheckboxNeedsTartInstalled() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        model.setTartInstalledForTesting(false)
        model.setTartLinux(true)
        XCTAssertNil(try saved(.tart), "nothing is written while tart is missing")
        XCTAssertFalse(model.tartLinuxOn)
    }

    func testTartLinuxCheckboxReportsAConfigThatCannotBeWritten() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        model.setTartInstalledForTesting(true)
        try "- just\n- a list\n".write(to: configURL, atomically: true, encoding: .utf8)

        model.setTartLinux(true)

        XCTAssertEqual(model.busyLine.style, .error, "the failure is on the status line, not silent")
        XCTAssertFalse(model.tartLinuxOn, "the checkbox doesn't claim a write that didn't happen")
    }

    func testTartLinuxWarnsWhileTheFleetStillAdvertisesMacOS() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        model.setTartInstalledForTesting(true)
        XCTAssertNil(model.tartLinuxLabelWarning, "no warning while tart serves macOS")

        try """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [self-hosted, macos, arm64]
        """.write(to: configURL, atomically: true, encoding: .utf8)
        model.reload()
        model.setTartInstalledForTesting(true)  // reload re-probes the real host
        model.setTartLinux(true)
        XCTAssertNotNil(model.tartLinuxLabelWarning)

        try """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [self-hosted, linux, arm64]
        base_image: "ghcr.io/cirruslabs/ubuntu:latest"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        model.reload()
        XCTAssertNil(model.tartLinuxLabelWarning, "fixed labels clear the warning")
    }

    func testMacOSAndCustomBaseImagesAreNotTartLinux() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        model.setTartInstalledForTesting(true)
        model.saveBaseImage("ghcr.io/cirruslabs/macos-sequoia-base:latest", for: .tart)
        XCTAssertFalse(model.tartLinuxOn)
        model.saveBaseImage("my-local-vm", for: .tart)
        XCTAssertFalse(model.tartLinuxOn, "a name kinhin can't classify isn't claimed as Linux")
        model.saveBaseImage("ghcr.io/cirruslabs/debian:latest", for: .tart)
        XCTAssertTrue(model.tartLinuxOn)
    }

    // MARK: - Mac tools form

    func testMacToolsFormShowsThePickerOnlyWhileTheRuntimeIsEnabled() throws {
        let model = MacToolsModel()
        model.configURL = configURL
        model.reload()
        XCTAssertTrue(model.containerOn, "the picker is shown while the runtime is enabled")
        model.saveBaseImage("debian:12", for: .appleContainer)
        XCTAssertEqual(try saved(.appleContainer), "debian:12")
        XCTAssertEqual(model.containerBaseImage, "debian:12")

        model.setContainerForTesting(false)
        XCTAssertFalse(model.containerOn, "hidden once the runtime is off")
        model.setContainerForTesting(true)
        XCTAssertEqual(model.containerBaseImage, nil, "a re-enabled section starts from the saved default")
    }
}

extension KinhinConfig {
    fileprivate func baseImageForTesting(_ runtime: RuntimeID) -> String? {
        switch runtime {
        case .tart: return baseImage
        case .appleContainer: return container?.baseImage
        case .docker: return docker?.baseImage
        case .host: return nil
        }
    }
}
