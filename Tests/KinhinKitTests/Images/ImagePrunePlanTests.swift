import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// `ImagePrunePlan` — selecting the sweep (stale derived records + unused
/// local images) without ever taking a configured image, the configured
/// `base_image:`, or anything in use — and executing through the shared
/// delete path with the fake tart and a temp-directory store.
final class ImagePrunePlanTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-ipp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)  // test temp dir
    }

    private func config(image: String = "tahoe-base") -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.image = image
        return cfg
    }

    private func record(_ name: String) -> ProjectImageRecord {
        ProjectImageRecord(
            name: name, key: name, base: "tahoe-base", summary: "go@1.22.5",
            createdAt: Date(timeIntervalSince1970: 0), lastUsedAt: Date(timeIntervalSince1970: 1000),
            toolchains: .init(KinhinConfig.ToolchainsConfig()), shareCache: false)
    }

    private func store(with names: [String]) -> ProjectImageStore {
        let store = ProjectImageStore(directory: dir)
        for name in names { store.upsert(record(name)) }
        return store
    }

    // MARK: - Selection

    func testSelectsStaleRecordsAndUnusedLocalImages() {
        let inventory = ImageInventory.build(
            config: config(),
            tart: .init(names: ["tahoe-base", "old-vm"], sizesGB: ["old-vm": 5]),
            projectRecords: [record("proj-gone")])

        let plan = ImagePrunePlan.plan(inventory: inventory, config: config())

        XCTAssertEqual(plan.targets.map(\.name), ["proj-gone", "old-vm"])
        XCTAssertEqual(plan.targets[0].present, false, "a stale record goes with no image on disk")
        XCTAssertEqual(plan.targets[0].stale, true)
        XCTAssertEqual(plan.targets[0].role, .derived)
        XCTAssertEqual(plan.targets[1].present, true)
        XCTAssertEqual(plan.targets[1].role, .local)
        XCTAssertEqual(plan.targets[1].sizeGB, 5)
        XCTAssertEqual(plan.reclaimGB, 5, "the report estimates the space the sweep frees")
        XCTAssertEqual(plan.inUse, [])
        XCTAssertEqual(plan.unavailable, [:])
    }

    func testReclaimIsUnknownWhenTheRuntimeReportedNoSizes() {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["old-vm"]), projectRecords: [record("proj-gone")])

        XCTAssertNil(
            ImagePrunePlan.plan(inventory: inventory, config: config()).reclaimGB,
            "no sizes means no estimate, never a guess of zero")
    }

    func testConfiguredAndDerivedImagesAreNeverCandidates() {
        var cfg = config()
        cfg.images = [.init(name: "xcode")]
        let inventory = ImageInventory.build(
            config: cfg,
            tart: .init(names: ["tahoe-base", "xcode", "proj-abc"]),
            projectRecords: [record("proj-abc")])

        let plan = ImagePrunePlan.plan(inventory: inventory, config: cfg)

        XCTAssertEqual(plan.targets, [], "base, named and present derived images are configured, not clutter")
    }

    func testTheConfiguredBaseImageIsProtectedEvenWhenItsRoleIsLocal() {
        var cfg = config()
        cfg.baseImage = "my-ubuntu"
        let tartOnly = ImageInventory.build(config: cfg, tart: .init(names: ["my-ubuntu"]))
        XCTAssertEqual(
            ImagePrunePlan.plan(inventory: tartOnly, config: cfg).targets, [],
            "base_image: may name any local VM — sweeping it would break the next bake")

        // A local OCI image may be the base the next bake pulls from too.
        var docker = config()
        docker.docker = .init(image: "kinhin-ci-linux", baseImage: "debian:12")
        let inventory = ImageInventory.build(
            config: docker,
            tart: .init(names: ["tahoe-base"]),
            docker: .init(names: ["debian:12", "kinhin-ci-linux:latest"]))
        XCTAssertEqual(
            ImagePrunePlan.plan(inventory: inventory, config: docker).targets, [],
            "docker.base_image and docker.image are both off limits")
    }

    func testAnInUseLocalImageIsKeptAndListed() {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["source-vm"]),
            fleet: [vmRecord("kinhin-1", image: "source-vm")])

        let plan = ImagePrunePlan.plan(
            inventory: inventory, config: config(), fleet: [vmRecord("kinhin-1", image: "source-vm")])

        XCTAssertEqual(plan.targets, [], "runners are running from it")
        XCTAssertEqual(plan.inUse.count, 1)
        XCTAssertEqual(plan.inUse[0].name, "source-vm")
        XCTAssertEqual(plan.inUse[0].runtime, .tart)
        XCTAssertEqual(plan.inUse[0].runners, ["kinhin-1"])
    }

    func testAStaleRecordAStillRunningVMAnswersToIsKept() {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["tahoe-base"]),
            projectRecords: [record("proj-gone")])

        let plan = ImagePrunePlan.plan(
            inventory: inventory, config: config(), fleet: [vmRecord("kinhin-1", image: "proj-gone")])

        XCTAssertEqual(plan.targets, [], "the record still describes a live VM's image")
    }

    func testARuntimeThatCouldNotBeListedIsReportedAndNeverSweptBlind() {
        let inventory = ImageInventory.build(
            config: config(),
            tart: .init(unavailable: "tart is not installed — brew install cirruslabs/tart/tart"),
            projectRecords: [record("proj-gone")])

        let plan = ImagePrunePlan.plan(inventory: inventory, config: config())

        XCTAssertEqual(plan.unavailable, ["tart": "tart is not installed — brew install cirruslabs/tart/tart"])
        XCTAssertEqual(plan.targets, [], "without a listing nothing is known to be unused")
    }

    // MARK: - Execution

    func testExecutePrunesThroughTheSharedDeletePath() async throws {
        let store = store(with: ["proj-abc", "proj-gone"])
        let tart = FakeTart()
        tart.vms["old-vm"] = TartVM(name: "old-vm", source: "local", status: "stopped")
        let inventory = ImageInventory.build(
            config: config(),
            tart: .init(names: ["tahoe-base", "proj-abc", "old-vm"]),
            projectRecords: [record("proj-abc"), record("proj-gone")])

        let plan = ImagePrunePlan.plan(inventory: inventory, config: config())
        try await plan.execute(tart: tart, container: nil, docker: nil, store: store)

        XCTAssertEqual(tart.deleteCalls, ["old-vm"], "only the unused image is deleted")
        XCTAssertEqual(
            store.all.map(\.name), ["proj-abc"],
            "the stale record is cleared; the live derived record stays")
    }

    private func vmRecord(_ id: String, image: String? = nil) -> VMRecord {
        var record = VMRecord(id: id)
        record.image = image
        return record
    }

    /// A runtime whose instances could not be listed is skipped, never swept:
    /// an empty `usedBy` there does not mean the image is unused.
    func testSkipsRuntimeWhoseInstancesCouldNotBeListed() {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["tahoe-base"]),
            docker: .init(names: ["old:1"], usageUnknown: "could not list docker instances: boom"))

        let plan = ImagePrunePlan.plan(inventory: inventory, config: config())

        XCTAssertEqual(plan.targets, [])
        XCTAssertEqual(plan.unavailable, ["docker": "could not list docker instances: boom"])
    }
}
