import XCTest

@testable import KinhinKit
@testable import kinhin_app

/// The staged half of the Runtimes page: the Keep idle floors and the fleet capacity fields stage in `CapacityModel`,
/// are checked by the engine's own `min_idle` rules before they can be applied, and write through the matching editor
/// on Apply.
@MainActor
final class CapacityKeepIdleTests: XCTestCase {
    private var configURL: URL!

    private let config = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: ["self-hosted"]
        max_runners: 6
        image_min_idle: 1
        images:
          - name: xcode
            base_image: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"
            labels: ["xcode"]
        container:
          image: "kinhin-ci-linux"
          cpus: 2
          memory_gb: 4
        docker:
          image: "kinhin-ci-linux"
          max_slots: 3
        """

    override func setUp() async throws {
        try await super.setUp()
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinhin-capacity-\(UUID().uuidString).yaml")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: configURL)
        try await super.tearDown()
    }

    private func loaded() -> CapacityModel {
        let model = CapacityModel()
        model.configURL = configURL
        model.reload()
        return model
    }

    private func snapshot() throws -> GeneralConfigEditor.Snapshot {
        try XCTUnwrap(try ConfigStore.snapshot(at: configURL))
    }

    private func set(_ model: CapacityModel, _ id: String, _ value: Int, _ make: (Int) -> GeneralConfigEditor.Field) {
        model.set(id, to: value, in: CapacityModel.keepIdleRange, make: make)
    }

    // MARK: - Staging

    func testKeepIdleStepsStageAndApplyThroughTheirEditors() throws {
        let model = loaded()
        var edited = 0
        model.onChanged = { edited += 1 }

        set(model, "image-min-idle", 2) { .imageMinIdle($0) }
        set(model, "container-min-idle", 2) { .containerMinIdle($0) }
        set(model, "docker-min-idle", 1) { .dockerMinIdle($0) }
        model.setImageMinIdle("xcode", to: 0)  // unchanged from disk: not staged
        XCTAssertEqual(model.pendingCount, 3)
        XCTAssertEqual(try snapshot().imageMinIdle, 1, "nothing is written while editing")

        model.applyPending()
        let snap = try snapshot()
        XCTAssertEqual(snap.imageMinIdle, 2)
        XCTAssertEqual(snap.container?.minIdle, 2)
        XCTAssertEqual(snap.docker?.minIdle, 1)
        XCTAssertEqual(edited, 1, "one engine reload for the whole batch")
        XCTAssertFalse(model.hasPendingChanges)
        XCTAssertEqual(model.status.text, "Applied ✓")
    }

    func testImageKeepIdleWritesThroughTheImagesEditorAndKeepsTheRest() throws {
        let model = loaded()
        model.setImageMinIdle("xcode", to: 1)
        XCTAssertEqual(model.imageMinIdle("xcode"), 1)
        XCTAssertTrue(model.hasPendingChanges)
        model.applyPending()
        let image = try XCTUnwrap(try snapshot().images.first)
        XCTAssertEqual(image.minIdle, 1)
        XCTAssertEqual(image.labels, ["xcode"], "the image's other keys survive the rewrite")
        XCTAssertEqual(image.baseImage, "ghcr.io/cirruslabs/macos-tahoe-xcode:latest")
    }

    func testReturningAStepperToItsSavedValueUnstagesIt() {
        let model = loaded()
        set(model, "docker-min-idle", 2) { .dockerMinIdle($0) }
        XCTAssertTrue(model.hasPendingChanges)
        set(model, "docker-min-idle", 0) { .dockerMinIdle($0) }
        XCTAssertFalse(model.hasPendingChanges)
        model.setImageMinIdle("xcode", to: 1)
        model.setImageMinIdle("xcode", to: 0)
        XCTAssertFalse(model.hasPendingChanges)
    }

    func testRevertDropsStagedKeepIdleValues() {
        let model = loaded()
        set(model, "container-min-idle", 3) { .containerMinIdle($0) }
        model.setImageMinIdle("xcode", to: 1)
        model.revert()
        XCTAssertFalse(model.hasPendingChanges)
        XCTAssertEqual(model.draft?.container?.minIdle, 0)
        XCTAssertEqual(model.imageMinIdle("xcode"), 0)
        XCTAssertTrue(model.minIdleIssues.isEmpty)
    }

    // MARK: - Validation

    func testDockerFloorAboveMaxSlotsShowsUnderDockerAndBlocksApply() throws {
        let model = loaded()
        set(model, "docker-min-idle", 5) { .dockerMinIdle($0) }  // docker.max_slots is 3
        let issue = try XCTUnwrap(model.issue(for: .dockerMinIdle))
        XCTAssertTrue(issue.contains("docker.max_slots"), issue)
        XCTAssertFalse(model.canApply)
        XCTAssertEqual(model.status.style, .error)
        XCTAssertTrue(model.status.text.hasPrefix("Not applied — "), model.status.text)
        model.applyPending()
        XCTAssertEqual(try snapshot().docker?.minIdle, 0, "Apply does nothing while a rule is broken")

        // Raising "Most at once" in the same batch makes the floor legal again.
        model.set("docker-max-slots", to: 6, in: 1...64) { .dockerMaxSlots($0) }
        XCTAssertNil(model.issue(for: .dockerMinIdle))
        XCTAssertTrue(model.canApply)
        model.applyPending()
        XCTAssertEqual(try snapshot().docker?.minIdle, 5)
        XCTAssertEqual(try snapshot().docker?.maxSlots, 6)
    }

    func testMacOSImageFloorsOverTwoShowOnTheMacOSLimit() throws {
        let model = loaded()  // image_min_idle 1
        model.setImageMinIdle("xcode", to: 2)  // 1 + 2 = 3 macOS VMs
        let issue = try XCTUnwrap(model.issue(for: .macOS))
        XCTAssertTrue(issue.contains("\(MinIdleValidation.macOSVMsPerMac)"), issue)
        XCTAssertFalse(model.canApply)
        model.setImageMinIdle("xcode", to: 1)
        XCTAssertNil(model.issue(for: .macOS))
        XCTAssertTrue(model.canApply)
    }

    func testFloorsAddingPastMostVMsShowOnTheTotal() throws {
        let model = loaded()  // max_runners 6
        set(model, "container-min-idle", 4) { .containerMinIdle($0) }
        set(model, "docker-min-idle", 2) { .dockerMinIdle($0) }  // 1 + 0 + 4 + 2 = 7 > 6
        XCTAssertNotNil(model.issue(for: .total))
        XCTAssertFalse(model.canApply)
        model.set("max-runners", to: 8, in: 1...32) { .maxRunners($0) }
        XCTAssertNil(model.issue(for: .total))
        XCTAssertTrue(model.canApply)
    }

    func testLoweringMostVMsBelowTheFloorsIsCaughtBeforeSaving() throws {
        let model = loaded()
        model.set("max-runners", to: 1, in: 1...32) { .maxRunners($0) }  // image_min_idle 1 + warm 0 still fits
        XCTAssertTrue(model.canApply)
        set(model, "container-min-idle", 2) { .containerMinIdle($0) }
        XCTAssertNotNil(model.issue(for: .containerMinIdle), "the pool's floor must fit most VMs at once")
        XCTAssertFalse(model.canApply)
    }

    func testNothingStagedMeansNoIssues() {
        let model = loaded()
        XCTAssertTrue(model.minIdleIssues.isEmpty)
        XCTAssertNil(model.issue(for: .total))
        XCTAssertFalse(model.canApply)
    }

    // MARK: - Staying in step with other writes

    func testRefreshFromDiskKeepsStagedEditsOnTopOfWhatChanged() throws {
        let model = loaded()
        set(model, "docker-min-idle", 2) { .dockerMinIdle($0) }
        // A route switch or an image edit elsewhere on the page wrote another key meanwhile.
        _ = try GeneralConfigEditor.apply(.pollInterval(90), to: configURL)
        model.refreshFromDisk()
        XCTAssertEqual(model.draft?.pollInterval, 90, "an untouched control follows the file")
        XCTAssertEqual(model.draft?.docker?.minIdle, 2, "a staged edit is not lost")
        XCTAssertEqual(model.pendingCount, 1)
    }

    func testReserveDiskIsStagedAndWritten() throws {
        let model = loaded()
        model.set("reserve-disk", to: 40, in: 0...500) { .reserveDiskGB($0) }
        model.applyPending()
        XCTAssertEqual(try snapshot().reserveDiskGB, 40)
    }
}
