import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// Advanced → Routing's Container pools: one card per named pool with what it resolves to and whether its image is
/// built, and the sheet's add / edit plus Remove writing `container.pools:`. Driven through `RuntimesModel`'s state
/// and actions, so no test opens real UI; the image listing is injected.
@MainActor
final class ContainerPoolsRoutingTests: XCTestCase {
    private var configURL: URL!
    private var removalAnswer = true
    private var removalPrompts: [String] = []
    private var listings = 0

    private static let head = """
        accounts:
          - name: github
            forge: github
            scope: "acme"
        labels: [self-hosted, arm64]
        max_runners: 10

        """

    private static let twoPools =
        head + """
            container:
              cpus: 2
              memory_gb: 7
              pools:
                linux: { image: kinhin-ci-linux, labels: [linux], min_idle: 1 }
                big:
                  image: kinhin-ci-big
                  labels: [linux, big]
                  cpus: 4
                  memory_gb: 12
                  docker: true
                  max: 2
                  fleet_labels: false

            """

    override func setUp() async throws {
        try await super.setUp()
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-container-pools-\(UUID().uuidString).yaml")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configURL)
        try await super.tearDown()
    }

    private func write(_ yaml: String) throws { try yaml.write(to: configURL, atomically: true, encoding: .utf8) }

    private func text() throws -> String { try String(contentsOf: configURL, encoding: .utf8) }

    /// A model on the scratch config, loaded (both passes), whose image listing returns `images` (nil: it fails).
    private func loadedModel(images: [String]? = ["kinhin-ci-linux:latest"]) async -> RuntimesModel {
        let model = RuntimesModel()
        model.configURL = configURL
        model.listContainerImages = { [unowned self] in
            listings += 1
            guard let images else { throw ConfigEditError.unsupported("container image list failed") }
            return images
        }
        model.confirmRemoval = { [unowned self] title, _, _ in
            removalPrompts.append(title)
            return removalAnswer
        }
        model.presentNotice = { _, _ in }
        await model.reloadWithHealth()
        return model
    }

    // MARK: - Cards

    func testEachPoolHasACardSayingWhatItResolvesToAndWhetherItIsBuilt() async throws {
        try write(Self.twoPools)
        let model = await loadedModel()
        XCTAssertTrue(model.showsContainerPools)
        let rows = model.containerPoolRows
        XCTAssertEqual(rows.map(\.id), ["big", "linux"])

        let big = try XCTUnwrap(rows.first { $0.id == "big" })
        XCTAssertEqual(big.built, false)
        XCTAssertFalse(big.isDefault)
        for fact in [
            "labels: linux, big, kinhin-container-big", "4 vCPU · 12 GB", "at most 2 at once", "Docker on",
            "image: kinhin-ci-big", "kinhin image prepare --container --pool big",
        ] {
            XCTAssertTrue(big.detail.contains(fact), "\(fact) missing from:\n\(big.detail)")
        }
        XCTAssertEqual(RuntimesModel.builtChip(big.built)?.style, .warn)

        let linux = try XCTUnwrap(rows.first { $0.id == "linux" })
        XCTAssertEqual(linux.built, true, "kinhin-ci-linux matches kinhin-ci-linux:latest")
        XCTAssertTrue(linux.isDefault, "the pool with the fewest labels takes unmatched jobs")
        for fact in ["2 vCPU · 7 GB", "min idle 1", "Docker off", "takes unmatched jobs"] {
            XCTAssertTrue(linux.detail.contains(fact), "\(fact) missing from:\n\(linux.detail)")
        }
        XCTAssertFalse(linux.detail.contains("at most"), "no max: no limit shown")
        XCTAssertEqual(RuntimesModel.builtChip(linux.built)?.style, .ok)
    }

    func testAFailedImageListingMarksNoPool() async throws {
        try write(Self.twoPools)
        let model = await loadedModel(images: nil)
        XCTAssertEqual(model.containerPoolRows.map(\.built), [nil, nil], "unknown, not every pool unbuilt")
        XCTAssertNil(RuntimesModel.builtChip(nil))
    }

    func testASectionWithoutPoolsHasNoCardsAndListsNothing() async throws {
        try write(Self.head + "container:\n  image: kinhin-ci-linux\n")
        let model = await loadedModel()
        XCTAssertTrue(model.showsContainerPools, "the section still offers Add Container Pool…")
        XCTAssertEqual(model.containerPoolRows, [])
        XCTAssertEqual(listings, 0)
    }

    func testWithoutAppleContainerTheSectionIsHidden() async throws {
        try write(Self.head)
        let model = await loadedModel()
        XCTAssertFalse(model.showsContainerPools)
    }

    // MARK: - Add / edit

    func testAddingAPoolWritesIt() async throws {
        try write(Self.twoPools)
        let model = await loadedModel()
        var edits = 0
        model.onChanged = { edits += 1 }
        model.addContainerPoolClicked()
        let offer = try XCTUnwrap(model.containerPoolOffer)
        XCTAssertNil(offer.original)
        XCTAssertFalse(offer.isFirstPool)
        XCTAssertEqual(offer.defaults.cpus, 2, "the placeholders show the section's values")

        var draft = ContainerPoolDraft()
        draft.name = "gpu"
        draft.labels = "gpu"
        draft.image = "kinhin-ci-gpu"
        draft.cpus = "3"
        model.confirmContainerPool(draft)
        XCTAssertNil(model.containerPoolOffer, "the sheet closes after a successful write")
        XCTAssertEqual(edits, 1)
        let container = try XCTUnwrap(ConfigLoader.parse(text()).container)
        XCTAssertEqual(container.pools.map(\.name), ["big", "gpu", "linux"])
        XCTAssertEqual(container.pool(named: "gpu").cpus, 3)
        XCTAssertEqual(container.pool(named: "gpu").memoryGB, 7, "a blank field inherits the section's value")
        XCTAssertEqual(container.pool(named: "big").fleetLabels, false, "the other pools are kept as written")
    }

    func testTheFirstPoolSaysItReplacesTheSinglePool() async throws {
        try write(Self.head + "container:\n  image: kinhin-ci-linux\n")
        let model = await loadedModel()
        model.addContainerPoolClicked()
        XCTAssertEqual(model.containerPoolOffer?.isFirstPool, true)
    }

    func testProblemsStayInTheSheetAndWriteNothing() async throws {
        try write(Self.twoPools)
        let before = try text()
        let model = await loadedModel()
        model.addContainerPoolClicked()

        var draft = ContainerPoolDraft()
        draft.name = "Big"
        model.confirmContainerPool(draft)
        XCTAssertFalse(model.sheetProblem.isEmpty, "the field check")
        XCTAssertNotNil(model.containerPoolOffer, "the sheet stays open with the values")

        draft.name = "twin"
        draft.labels = "linux"
        draft.image = "kinhin-ci-linux"
        model.confirmContainerPool(draft)
        XCTAssertTrue(model.sheetProblem.contains("same labels"), "the loader's verdict: \(model.sheetProblem)")
        XCTAssertNotNil(model.containerPoolOffer)
        XCTAssertEqual(try text(), before)

        model.cancelContainerPool()
        XCTAssertNil(model.containerPoolOffer)
        XCTAssertEqual(model.sheetProblem, "")
    }

    func testEditingAPoolKeepsWhatTheSheetDoesNotShow() async throws {
        try write(Self.twoPools)
        let model = await loadedModel()
        model.editContainerPoolClicked(name: "big")
        let offer = try XCTUnwrap(model.containerPoolOffer)
        let original = try XCTUnwrap(offer.original)
        XCTAssertEqual(original.cpus, 4)
        XCTAssertNil(original.minIdle, "the pool as written, not with the section's defaults")

        var draft = ContainerPoolDraft(pool: original)
        draft.name = "large"
        draft.cpus = "6"
        model.confirmContainerPool(draft)
        XCTAssertNil(model.containerPoolOffer, model.sheetProblem)
        let container = try XCTUnwrap(ConfigLoader.parse(text()).container)
        XCTAssertEqual(container.pools.map(\.name), ["large", "linux"], "renamed in place")
        XCTAssertEqual(container.pool(named: "large").cpus, 6)
        XCTAssertEqual(container.pool(named: "large").fleetLabels, false)
        XCTAssertEqual(container.pool(named: "large").max, 2)
    }

    // MARK: - Remove

    func testRemovingAPoolAsksFirst() async throws {
        try write(Self.twoPools)
        let before = try text()
        let model = await loadedModel()
        removalAnswer = false
        model.removeContainerPool(name: "big")
        XCTAssertEqual(removalPrompts, ["Remove container pool “big”?"])
        XCTAssertEqual(try text(), before, "declined: nothing written")

        removalAnswer = true
        model.removeContainerPool(name: "big")
        XCTAssertEqual(try ConfigLoader.parse(text()).container?.pools.map(\.name), ["linux"])
    }
}
