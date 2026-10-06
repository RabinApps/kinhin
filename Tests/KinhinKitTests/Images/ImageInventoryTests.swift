import XCTest

@testable import KinhinKit

/// `ImageInventory.build` — how raw runtime listings become the classified
/// inventory `kinhin image list` prints: roles, sizes, who is using what,
/// configured-but-not-built, stale records, and runner VMs that are not
/// images at all.
final class ImageInventoryTests: XCTestCase {
    private func config(image: String = "tahoe-base") -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.image = image
        return cfg
    }

    private func vm(_ id: String, image: String? = nil) -> VMRecord {
        var record = VMRecord(id: id)
        record.image = image
        return record
    }

    private func record(_ name: String, summary: String = "go@1.22.5") -> ProjectImageRecord {
        ProjectImageRecord(
            name: name, key: name, base: "tahoe-base", summary: summary,
            createdAt: Date(timeIntervalSince1970: 0), lastUsedAt: Date(timeIntervalSince1970: 1000),
            toolchains: .init(KinhinConfig.ToolchainsConfig()), shareCache: false)
    }

    private func entry(_ inventory: ImageInventory, _ name: String) -> ImageInventory.Entry? {
        inventory.entries.first { $0.name == name }
    }

    func testClassifiesTartEntriesByRole() {
        var cfg = config()
        cfg.images = [.init(name: "xcode")]
        let inventory = ImageInventory.build(
            config: cfg,
            tart: .init(
                names: ["tahoe-base", "xcode", "proj-abc", "ubuntu-local"],
                sizesGB: ["tahoe-base": 33]),
            projectRecords: [record("proj-abc", summary: "xcode@15")])

        XCTAssertEqual(entry(inventory, "tahoe-base")?.role, .base)
        XCTAssertEqual(entry(inventory, "tahoe-base")?.sizeGB, 33)
        XCTAssertEqual(entry(inventory, "xcode")?.role, .named)
        let derived = entry(inventory, "proj-abc")
        XCTAssertEqual(derived?.role, .derived)
        XCTAssertEqual(derived?.summary, "xcode@15")
        XCTAssertEqual(derived?.lastUsedAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(entry(inventory, "ubuntu-local")?.role, .local)
        // No configured-but-not-built rows: everything asked for is listed.
        XCTAssertEqual(inventory.entries.filter { !$0.present }, [])
    }

    func testSectionTotalsAddUpTheInstalledImagesOnly() {
        var cfg = config()
        cfg.images = [.init(name: "xcode")]
        let inventory = ImageInventory.build(
            config: cfg,
            tart: .init(
                names: ["tahoe-base", "proj-abc"], sizesGB: ["tahoe-base": 33, "proj-abc": 12]),
            docker: .init(names: ["kinhin-ci-linux:latest"], sizesGB: ["kinhin-ci-linux:latest": 4]),
            projectRecords: [record("proj-abc")])

        let tart = inventory.sections.first { $0.runtime == .tart }!
        XCTAssertEqual(tart.totalGB, 45, "the total is the sum of what is on disk")
        XCTAssertEqual(tart.presentCount, 2, "configured-but-not-built rows do not count")

        let docker = inventory.sections.first { $0.runtime == .docker }!
        XCTAssertEqual(docker.totalGB, 4)
        XCTAssertEqual(docker.presentCount, 1)
    }

    func testSectionTotalIsNilWhenTheRuntimeReportedNoSizes() {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["tahoe-base"]),
            docker: .init(names: ["kinhin-ci-linux:latest"]))

        let tart = inventory.sections.first { $0.runtime == .tart }!
        XCTAssertEqual(tart.presentCount, 1)
        XCTAssertNil(
            tart.totalGB,
            "no sizes means no total — a zero would claim the images are free")
    }

    func testRunnerAndScratchVMsAreNotImages() {
        let inventory = ImageInventory.build(
            config: config(),
            tart: .init(names: ["tahoe-base", "kinhin-1717-abcd", "orchard-9", "kinhin-prepare-tmp-1"]),
            fleet: [vm("kinhin-1717-abcd")])

        XCTAssertEqual(inventory.entries.map(\.name), ["tahoe-base"])
    }

    /// A base image name that happens to carry the runner prefix is still
    /// the image kinhin knows — the prefix rule never hides config.
    func testAKnownImageSurvivesTheRunnerPrefixRule() {
        let inventory = ImageInventory.build(
            config: config(image: "kinhin-custom"),
            tart: .init(names: ["kinhin-custom", "kinhin-stray"]))

        XCTAssertEqual(inventory.entries.map(\.name), ["kinhin-custom"])
        XCTAssertEqual(entry(inventory, "kinhin-custom")?.role, .base)
    }

    func testConfiguredButNotBuiltAndStaleRecordsAppearOnlyWhenTheListingWorked() {
        var cfg = config()
        cfg.images = [.init(name: "xcode")]
        let inventory = ImageInventory.build(
            config: cfg, tart: .init(names: ["tahoe-base"]), projectRecords: [record("proj-gone")])

        let missing = inventory.entries.filter { !$0.present }
        XCTAssertEqual(missing.map(\.name), ["xcode", "proj-gone"])
        XCTAssertEqual(missing.first { $0.name == "xcode" }?.role, .named)
        let stale = missing.first { $0.name == "proj-gone" }
        XCTAssertEqual(stale?.stale, true, "a record without a disk image is a stale index entry")
        XCTAssertEqual(stale?.role, .derived)
    }

    func testAnUnavailableTartClaimsNothingAboutWhatIsBuilt() {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(unavailable: "tart is not installed"),
            projectRecords: [record("proj-abc")])

        XCTAssertEqual(inventory.sections.count, 1)
        XCTAssertEqual(inventory.sections[0].unavailable, "tart is not installed")
        XCTAssertEqual(inventory.entries, [], "without a listing there are no present, missing or stale rows")
    }

    func testBaseImageClaimsTheRunnersThatCarryNoImageField() {
        let inventory = ImageInventory.build(
            config: config(),
            tart: .init(names: ["tahoe-base", "proj-abc"]),
            fleet: [vm("kinhin-1"), vm("kinhin-2", image: "proj-abc")],
            projectRecords: [record("proj-abc")])

        XCTAssertEqual(entry(inventory, "tahoe-base")?.usedBy, ["kinhin-1"])
        XCTAssertEqual(entry(inventory, "proj-abc")?.usedBy, ["kinhin-2"])
    }

    func testContainerAndDockerSectionsMarkTheConfiguredImageAndItsUse() {
        var cfg = config()
        cfg.container = .init(image: "kinhin-ci-linux")
        cfg.docker = .init(image: "kinhin-ci-linux")
        let inventory = ImageInventory.build(
            config: cfg,
            tart: .init(names: ["tahoe-base"]),
            container: .init(names: ["kinhin-ci-linux:latest", "ubuntu:24.04"], instances: ["kinhin-42"]),
            docker: .init(names: []))

        XCTAssertEqual(inventory.sections.map(\.runtime), [.tart, .container, .docker])

        let latest = entry(inventory, "kinhin-ci-linux:latest")
        XCTAssertEqual(latest?.runtime, .container)
        XCTAssertEqual(latest?.role, .base)
        XCTAssertEqual(latest?.usedBy, ["kinhin-42"], "runner containers start from the configured tag")

        let ubuntu = entry(inventory, "ubuntu:24.04")
        XCTAssertEqual(ubuntu?.role, .local)
        XCTAssertEqual(ubuntu?.usedBy, [], "a bake source is nobody's runner image")

        let dockerMissing = inventory.entries.first { $0.runtime == .docker }
        XCTAssertEqual(dockerMissing?.name, "kinhin-ci-linux")
        XCTAssertEqual(dockerMissing?.present, false, "configured but not built")
        XCTAssertEqual(dockerMissing?.role, .base)
    }

    func testAnUnconfiguredLinuxRuntimeShowsLocalImagesWithoutNagging() {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["tahoe-base"]),
            container: .init(names: ["ubuntu:24.04"]))

        XCTAssertEqual(inventory.entries.filter { $0.runtime == .container }.map(\.name), ["ubuntu:24.04"])
        XCTAssertEqual(inventory.entries.filter { $0.runtime == .container && !$0.present }, [])
    }

    func testOnlyNarrowsTheInventoryToTheRequestedRuntimes() {
        var cfg = config()
        cfg.container = .init(image: "kinhin-ci-linux")
        cfg.docker = .init(image: "kinhin-ci-linux")
        let listings:
            (
                tart: ImageInventory.RuntimeImages, container: ImageInventory.RuntimeImages,
                docker: ImageInventory.RuntimeImages
            ) = (
                .init(names: ["tahoe-base"]), .init(names: ["kinhin-ci-linux"]), .init(names: [])
            )

        let all = ImageInventory.build(
            config: cfg, tart: listings.tart, container: listings.container, docker: listings.docker)
        XCTAssertEqual(all.sections.map(\.runtime), [.tart, .container, .docker])

        let dockerOnly = ImageInventory.build(
            config: cfg, tart: listings.tart, container: listings.container, docker: listings.docker,
            only: [.docker])
        XCTAssertEqual(dockerOnly.sections.map(\.runtime), [.docker])
        XCTAssertEqual(dockerOnly.entries.map(\.runtime), [.docker])

        let two = ImageInventory.build(
            config: cfg, tart: listings.tart, container: listings.container, docker: listings.docker,
            only: [.tart, .container])
        XCTAssertEqual(two.sections.map(\.runtime), [.tart, .container])
    }

    func testDanglingImageReferencesAreSkipped() {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["tahoe-base"]),
            docker: .init(names: ["<none>:<none>", "", "kinhin-ci-linux:latest"]))

        XCTAssertEqual(
            inventory.entries.filter { $0.runtime == .docker }.map(\.name), ["kinhin-ci-linux:latest"])
    }

    /// The configured docker image has no tag in the config; only `:latest`
    /// is what containers actually start from, so only it carries the users.
    func testOnlyTheTagRunnersStartFromCarriesTheUsers() {
        XCTAssertTrue(ImageInventory.ociMatches(name: "x:latest", wanted: "x"))
        XCTAssertTrue(ImageInventory.ociMatches(name: "x:v1", wanted: "x"))
        XCTAssertTrue(ImageInventory.ociMatches(name: "x:v1", wanted: "x:v1"))
        XCTAssertFalse(ImageInventory.ociMatches(name: "xy:latest", wanted: "x"))

        XCTAssertTrue(ImageInventory.ociUses(name: "x", wanted: "x"))
        XCTAssertTrue(ImageInventory.ociUses(name: "x:latest", wanted: "x"))
        XCTAssertFalse(ImageInventory.ociUses(name: "x:v1", wanted: "x"), "an old tag is not what is running")
    }
}
