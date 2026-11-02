import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// Review fixes for named container pools (#77): a pool name with a trailing newline, the tag a pool's runners start
/// from, doctor when the images cannot be listed, the base image that moves up with the last pool's image, the host
/// pool of an edited routing section, and the benchmark runtime.
final class ContainerPoolsReviewFixesTests: XCTestCase {
    private func pooled() -> KinhinConfig.ContainerConfig {
        .init(
            image: "kinhin-ci-linux",
            pools: [
                .init(name: "big", image: "kinhin-ci-big", cpus: 4, memoryGB: 12, labels: ["big"], max: 2),
                .init(name: "linux", image: "kinhin-ci-linux", cpus: 2, memoryGB: 7, docker: true),
            ])
    }

    func testAPoolNameCannotEndInANewline() {
        XCTAssertFalse(KinhinConfig.ContainerConfig.Pool.isValidName("a\n"))
        XCTAssertFalse(KinhinConfig.ContainerConfig.Pool.isValidName("big\r\n"))
        XCTAssertTrue(KinhinConfig.ContainerConfig.Pool.isValidName("a-1"))
    }

    func testOnlyTheTagARunnerStartsFromCountsAsBuilt() {
        let container = pooled()
        XCTAssertEqual(
            container.poolsMissingImage(listed: ["kinhin-ci-linux:latest", "kinhin-ci-big:old"]).map(\.name), ["big"],
            "container run kinhin-ci-big starts :latest, so :old does not make the pool runnable")
        XCTAssertEqual(container.poolsMissingImage(listed: ["kinhin-ci-linux", "kinhin-ci-big"]), [])
        var tagged = container
        tagged.pools[0].image = "kinhin-ci-big:2"
        XCTAssertEqual(tagged.poolsMissingImage(listed: ["kinhin-ci-big:2", "kinhin-ci-linux"]), [])
        XCTAssertEqual(tagged.poolsMissingImage(listed: ["kinhin-ci-big", "kinhin-ci-linux"]).map(\.name), ["big"])
    }

    func testDoctorCallsNoPoolBuiltWhenTheImagesCannotBeListed() throws {
        var cfg = KinhinConfig.default
        cfg.container = pooled()
        let section = try XCTUnwrap(
            DoctorReportBuilder.containerSection(
                config: cfg, health: .ready, images: .init(unavailable: "container image list failed")))
        XCTAssertFalse(section.imageFound)
        XCTAssertEqual(section.pools?.map(\.imageFound), [false, false], "the rows agree with the section")

        let wrongTag = try XCTUnwrap(
            DoctorReportBuilder.containerSection(
                config: cfg, health: .ready, images: .init(names: ["kinhin-ci-linux", "kinhin-ci-big:old"])))
        XCTAssertEqual(wrongTag.pools?.map(\.imageFound), [false, true], "the engine's rule: :old is not runnable")
        XCTAssertEqual(wrongTag.fix, "kinhin image prepare --container --pool big")
    }

    func testRemovingTheLastPoolMovesItsOwnBaseImageUpWithItsImage() throws {
        let section = GeneralConfigEditor.Snapshot.Container(
            image: "", cpus: 2, memoryGB: 4, baseImage: "ubuntu:24.04",
            pools: [.init(name: "a", image: "a-image", baseImage: "debian:12")])
        let updated = try ContainerPoolsConfigEditor.removing("a", from: section)
        XCTAssertEqual(updated.image, "a-image")
        XCTAssertEqual(updated.baseImage, "debian:12", "a-image is baked from debian:12, so the section must be too")

        let inherits = GeneralConfigEditor.Snapshot.Container(
            image: "", cpus: 2, memoryGB: 4, baseImage: "ubuntu:24.04", pools: [.init(name: "a", image: "a-image")])
        XCTAssertEqual(try ContainerPoolsConfigEditor.removing("a", from: inherits).baseImage, "ubuntu:24.04")
    }

    func testTheHostPoolFollowsTheRoutingTheTableIsBuiltFrom() {
        var cfg = makeTestConfig()
        cfg.runtimes = .init(defaultRuntime: .tart)
        let edited = KinhinConfig.RuntimeConfig(
            defaultRuntime: .tart, routes: [.init(pattern: "acme/widgets", runtime: .host, consent: true)])
        XCTAssertNotNil(RuntimeConfigModel(config: cfg, routing: edited).pools[.host], "a host route in the preview")
        XCTAssertNil(RuntimeConfigModel(config: cfg).pools[.host])
        cfg.runtimes = edited
        XCTAssertNil(
            RuntimeConfigModel(config: cfg, routing: .init(defaultRuntime: .tart)).pools[.host],
            "the preview removed the host route")
    }

    func testTheBenchmarkRunsTheDefaultPool() throws {
        var cfg = makeTestConfig()
        cfg.container = pooled()
        cfg.container?.cpus = 8
        let env = BenchmarkEnvironment(config: cfg, tart: FakeTart(), ssh: FakeSSH(), shell: FakeShell())
        let runtime = try XCTUnwrap(env.makeRuntime(.appleContainer, nil) as? AppleContainerRuntime)
        XCTAssertEqual(runtime.image, "kinhin-ci-linux")
        XCTAssertEqual(runtime.cpus, 2, "the default pool's shape, not the section's default")
        XCTAssertTrue(runtime.docker)
    }

    func testTheBenchmarkProbesTheDefaultPoolsImage() {
        var cfg = makeTestConfig()
        cfg.container = pooled()
        cfg.container?.image = "kinhin-ci-unused"
        let env = BenchmarkEnvironment(config: cfg, tart: FakeTart(), ssh: FakeSSH(), shell: FakeShell())
        XCTAssertEqual(
            env.image(for: .appleContainer), "kinhin-ci-linux",
            "the image the runtime starts, not a section image no pool runs")
    }
}
