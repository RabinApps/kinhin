import KinhinKit
import XCTest

@testable import kinhin

/// `kinhin image prepare --container`: the bare bake as before, one named pool's image with `--pool`, and every
/// pool's image with `--all` (#75, step 2).
final class ImageCommandContainerPoolsTests: XCTestCase {
    private let container = KinhinConfig.ContainerConfig(
        image: "kinhin-ci-linux", baseImage: "ubuntu:24.04", docker: false,
        pools: [
            .init(name: "big", image: "kinhin-ci-big", baseImage: "debian:12", labels: ["big"]),
            .init(name: "linux", image: "kinhin-ci-linux", baseImage: "ubuntu:24.04", docker: true),
        ])

    private func describe(_ bakes: [LinuxImageOptions]) -> [String] {
        bakes.map { "\($0.image) -> \($0.target)\($0.docker ? " +docker" : "")" }
    }

    func testABareBakeIsUnchanged() throws {
        let section = KinhinConfig.ContainerConfig(image: "kinhin-ci-linux", baseImage: "ubuntu:24.04", docker: true)
        XCTAssertEqual(
            describe(try ImageCommand.containerBakes(args: ["--container"], container: section)),
            ["ubuntu:24.04 -> kinhin-ci-linux +docker"])
        XCTAssertEqual(
            describe(
                try ImageCommand.containerBakes(
                    args: ["--container", "--target", "x", "--container-image", "debian:12"], container: section)),
            ["debian:12 -> x +docker"])
    }

    func testPoolBakesThatPoolsImage() throws {
        XCTAssertEqual(
            describe(try ImageCommand.containerBakes(args: ["--container", "--pool", "big"], container: container)),
            ["debian:12 -> kinhin-ci-big"])
        XCTAssertEqual(
            describe(try ImageCommand.containerBakes(args: ["--container", "--pool", "linux"], container: container)),
            ["ubuntu:24.04 -> kinhin-ci-linux +docker"])
    }

    func testAllBakesEveryPoolsImageOnce() throws {
        XCTAssertEqual(
            describe(try ImageCommand.containerBakes(args: ["--container", "--all"], container: container)),
            ["debian:12 -> kinhin-ci-big", "ubuntu:24.04 -> kinhin-ci-linux +docker"])
    }

    func testEachImageIsBakedForItsPoolsPlatform() throws {
        var pooled = container
        pooled.pools.append(.init(name: "x64", image: "kinhin-ci-x64", labels: ["x64-only"], platform: .amd64))
        let all = try ImageCommand.containerBakes(args: ["--container", "--all"], container: pooled)
        XCTAssertEqual(all.map(\.target), ["kinhin-ci-big", "kinhin-ci-linux", "kinhin-ci-x64"])
        XCTAssertEqual(all.map(\.platform), [.arm64, .arm64, .amd64])
        let flagged = try ImageCommand.containerBakes(
            args: ["--container", "--target", "x", "--platform", "linux/amd64"], container: container)
        XCTAssertEqual(flagged.map(\.platform), [.amd64], "--platform overrides the config for this bake")
        XCTAssertThrowsError(
            try ImageCommand.containerBakes(args: ["--container", "--platform", "s390x"], container: container))
    }

    func testUnknownPoolsAndTargetWithAllAreUsageErrors() {
        for args in [["--container", "--pool", "nope"], ["--container", "--all", "--target", "x"]] {
            XCTAssertThrowsError(try ImageCommand.containerBakes(args: args, container: container)) { error in
                XCTAssertEqual((error as? CLIError)?.exit, .usage, "\(args)")
            }
        }
        let section = KinhinConfig.ContainerConfig(image: "kinhin-ci-linux")
        XCTAssertThrowsError(
            try ImageCommand.containerBakes(args: ["--container", "--pool", "big"], container: section))
    }

    func testAContainerImageOverrideThatIsNotAReferenceIsRefused() {
        let section = KinhinConfig.ContainerConfig(image: "kinhin-ci-linux", baseImage: "ubuntu:24.04", docker: false)
        for bad in ["ubuntu:24.04\nRUN x", "a b", "-x"] {
            XCTAssertThrowsError(
                try ImageCommand.containerBakes(args: ["--container", "--container-image", bad], container: section),
                "\(bad.debugDescription)")
        }
    }
}
