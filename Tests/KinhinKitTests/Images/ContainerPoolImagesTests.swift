import XCTest

@testable import KinhinKit

/// Every named container pool's image (#75, step 2): which bake installs Docker and from which base, `image list`
/// marking each pool's image as configured, and `image prune` keeping them all.
final class ContainerPoolImagesTests: XCTestCase {
    private func config() -> KinhinConfig {
        var cfg = KinhinConfig.default
        cfg.image = "tahoe-base"
        cfg.container = .init(
            image: "kinhin-ci-linux", baseImage: "ubuntu:24.04",
            pools: [
                .init(name: "big", image: "kinhin-ci-big", baseImage: "debian:12", labels: ["big"]),
                .init(name: "dind", image: "kinhin-ci-linux", baseImage: "ubuntu:24.04", labels: ["d"], docker: true),
                .init(name: "linux", image: "kinhin-ci-linux", baseImage: "ubuntu:24.04"),
            ])
        return cfg
    }

    func testEachImageIsBakedOnceFromItsPoolsBase() throws {
        let container = try XCTUnwrap(config().container)
        XCTAssertEqual(container.poolImages, ["kinhin-ci-big", "kinhin-ci-linux"])
        XCTAssertEqual(container.baseImage(forImage: "kinhin-ci-big"), "debian:12")
        XCTAssertEqual(container.baseImage(forImage: "kinhin-ci-linux"), "ubuntu:24.04")
        XCTAssertEqual(
            container.baseImage(forImage: "unrelated"), "ubuntu:24.04", "an image no pool runs: the section's")
    }

    func testAnImageIsBakedWithDockerWhenAPoolThatRunsItHasDocker() throws {
        let container = try XCTUnwrap(config().container)
        XCTAssertTrue(container.bakesDocker(image: "kinhin-ci-linux"), "dind runs it with Docker; linux shares it")
        XCTAssertFalse(container.bakesDocker(image: "kinhin-ci-big"))
        XCTAssertFalse(container.bakesDocker(image: "unrelated"), "an image no pool runs follows the section")
    }

    func testWithoutPoolsTheSectionsDockerDecidesEveryBake() {
        let section = KinhinConfig.ContainerConfig(image: "kinhin-ci-linux", docker: true)
        XCTAssertTrue(section.bakesDocker(image: "kinhin-ci-linux"))
        XCTAssertTrue(section.bakesDocker(image: "custom-target"), "as before pools: `--target` keeps the section's")
        XCTAssertEqual(section.poolImages, ["kinhin-ci-linux"])
    }

    func testImageListMarksEveryPoolsImage() {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["tahoe-base"]),
            container: .init(names: ["kinhin-ci-linux:latest", "ubuntu:24.04"], instances: ["kinhin-1"]))
        let container = inventory.entries.filter { $0.runtime == .container }
        XCTAssertEqual(container.first { $0.name == "kinhin-ci-linux:latest" }?.role, .base)
        let big = container.first { $0.name == "kinhin-ci-big" }
        XCTAssertEqual(big?.role, .base)
        XCTAssertEqual(big?.present, false, "a pool's image that is not built yet is listed as missing")
        XCTAssertEqual(container.first { $0.name == "ubuntu:24.04" }?.role, .local)
    }

    func testPruneKeepsEveryPoolsImageAndBase() {
        let inventory = ImageInventory.build(
            config: config(), tart: .init(names: ["tahoe-base"]),
            container: .init(names: ["kinhin-ci-linux", "kinhin-ci-big", "debian:12", "ubuntu:24.04", "old"]))
        let plan = ImagePrunePlan.plan(inventory: inventory, config: config())
        XCTAssertEqual(plan.targets.map(\.name), ["old"])
    }
}
