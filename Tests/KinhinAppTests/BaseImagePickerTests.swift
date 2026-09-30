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
        let model = ToolchainsModel()
        model.configURL = configURL
        model.reload()

        model.saveBaseImage(pinned, for: .tart)
        XCTAssertEqual(try saved(.tart), pinned)
        XCTAssertEqual(model.baseImage(for: .tart), pinned)
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
        let model = ToolchainsModel()
        model.configURL = configURL
        model.reload()

        model.saveBaseImage("ghcr.io/cirruslabs/macos-sequoia-base:latest", for: .tart)
        XCTAssertEqual(try saved(.tart), "ghcr.io/cirruslabs/macos-sequoia-base:latest")

        model.saveBaseImage(nil, for: .tart)
        XCTAssertNil(try saved(.tart), "the default clears the key")
    }

    // MARK: - Toolchains page

    func testToolchainsPageOffersAPickerForEachLinuxRuntimeAndSavesIt() throws {
        let model = ToolchainsModel()
        model.configURL = configURL
        model.reload()
        XCTAssertEqual(
            Set(model.imageRuntimes.map(\.runtime).filter { $0 != .tart }), [.appleContainer, .docker])

        var edited = 0
        model.onChanged = { edited += 1 }
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
        try "labels: [self-hosted]\ncontainer:\n  image: \"kinhin-ci-linux\"\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        model.saveBaseImage("debian:12", for: .docker)
        XCTAssertEqual(alerts, 1, "the failure is shown")
        XCTAssertNil(model.baseImage(for: .docker), "the page shows what is actually saved")
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
