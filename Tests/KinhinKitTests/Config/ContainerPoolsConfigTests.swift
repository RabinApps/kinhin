import XCTest

@testable import KinhinKit

/// `container.pools` (#75, step 2): parsing with the section's keys as defaults, the single-pool shape it leaves
/// alone, what the loader rejects, and the editors that rewrite `container:` keeping every pool.
final class ContainerPoolsConfigTests: XCTestCase {
    private static let head = """
        accounts:
          - name: github
            forge: github
            scope: "acme"
        labels: [self-hosted, arm64]
        max_runners: 10

        """

    /// The example from the issue: top-level defaults, a small pool and a big one.
    private static let twoPools = """
        container:
          cpus: 2
          memory_gb: 7
          docker: true
          pools:
            linux: { image: kinhin-ci-linux, labels: [linux], min_idle: 1 }
            big:
              image: kinhin-ci-linux
              labels: [linux, big]
              cpus: 4
              memory_gb: 12
              flags: ["--shm-size", "2g"]
              max: 2

        """

    private func parse(_ container: String) throws -> KinhinConfig {
        try ConfigLoader.parse(Self.head + container)
    }

    private func invalidMessage(_ container: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try parse(container)
            XCTFail("expected a ConfigError for:\n\(container)", file: file, line: line)
            return ""
        } catch ConfigError.invalid(let why) {
            return why
        } catch {
            XCTFail("expected ConfigError.invalid, got \(error)", file: file, line: line)
            return ""
        }
    }

    // MARK: - Without pools: exactly as before

    func testASectionWithoutPoolsIsItsOneUnnamedPool() throws {
        let cfg = try parse(
            "container:\n  image: kinhin-ci-linux\n  cpus: 3\n  memory_gb: 6\n  labels: [linux]\n  min_idle: 1\n"
                + "  docker: true\n  flags: [\"--init\"]\n")
        let container = try XCTUnwrap(cfg.container)
        XCTAssertEqual(container.pools, [])
        XCTAssertEqual(
            container,
            KinhinConfig.ContainerConfig(
                image: "kinhin-ci-linux", cpus: 3, memoryGB: 6, labels: ["linux"], minIdle: 1, docker: true,
                flags: ["--init"]),
            "the parsed section is what it was before pools existed")
        XCTAssertEqual(
            container.effectivePools,
            [
                .init(
                    name: "", image: "kinhin-ci-linux", cpus: 3, memoryGB: 6, labels: ["linux"], minIdle: 1,
                    docker: true, flags: ["--init"])
            ])
        XCTAssertEqual(container.defaultPool.name, "")
        XCTAssertNil(container.defaultPool.marker, "the unnamed pool adds no label")
        XCTAssertEqual(container.pool(named: nil), container.defaultPool)
        XCTAssertEqual(container.poolImages, ["kinhin-ci-linux"])
    }

    // MARK: - Parsing pools

    func testPoolsInheritTheSectionKeysTheyLeaveOut() throws {
        let container = try XCTUnwrap(try parse(Self.twoPools).container)
        XCTAssertEqual(container.pools.map(\.name), ["big", "linux"], "sorted by name")
        XCTAssertEqual(
            container.pool(named: "linux"),
            .init(
                name: "linux", image: "kinhin-ci-linux", cpus: 2, memoryGB: 7, labels: ["linux"], minIdle: 1,
                docker: true))
        XCTAssertEqual(
            container.pool(named: "big"),
            .init(
                name: "big", image: "kinhin-ci-linux", cpus: 4, memoryGB: 12, labels: ["linux", "big"], docker: true,
                flags: ["--shm-size", "2g"], max: 2))
        XCTAssertEqual(container.pool(named: "big").marker, "kinhin-container-big")
        XCTAssertEqual(container.image, "kinhin-ci-linux", "the section's image is the default pool's")
        XCTAssertEqual(container.poolImages, ["kinhin-ci-linux"], "a shared image is listed once")
    }

    func testTheDefaultPoolHasTheFewestLabelsThenTheFirstName() throws {
        let container = try XCTUnwrap(try parse(Self.twoPools).container)
        XCTAssertEqual(container.defaultPool.name, "linux")
        XCTAssertEqual(container.pool(named: "gone").name, "linux", "a removed pool resolves to the default one")
        let tie = try XCTUnwrap(
            try parse("container:\n  image: i\n  pools:\n    b: { labels: [x] }\n    a: { labels: [y] }\n").container)
        XCTAssertEqual(tie.defaultPool.name, "a")
        let catchAll = try XCTUnwrap(
            try parse("container:\n  image: i\n  pools:\n    a: { labels: [x] }\n    z: {}\n").container)
        XCTAssertEqual(catchAll.defaultPool.name, "z", "a pool without labels catches the rest")
    }

    func testTheSectionImageIsTheDefaultForPoolsWithoutOne() throws {
        let container = try XCTUnwrap(
            try parse("container:\n  image: base-img\n  pools:\n    a: { labels: [a] }\n    b: { image: b-img }\n")
                .container)
        XCTAssertEqual(container.pool(named: "a").image, "base-img")
        XCTAssertEqual(container.pool(named: "b").image, "b-img")
        XCTAssertEqual(container.image, "base-img")
        XCTAssertEqual(container.poolImages, ["base-img", "b-img"])
    }

    func testTheSectionsMinIdleIsADefaultNotAnExtraFloor() throws {
        let container = try XCTUnwrap(
            try parse("container:\n  image: i\n  min_idle: 1\n  pools:\n    a: { labels: [a] }\n    b: {}\n").container)
        XCTAssertEqual(container.effectivePools.map(\.minIdle), [1, 1])
    }

    func testTheKeysAreKnownToTheSchema() throws {
        XCTAssertEqual(try ConfigSchema.unknownKeys(in: Self.twoPools), [])
    }

    func testAnUnknownPoolKeyIsRejectedWithASuggestion() throws {
        let unknown = try ConfigSchema.unknownKeys(in: "container:\n  pools:\n    big:\n      cpu: 4\n")
        XCTAssertEqual(unknown.map(\.path), ["container.pools.big.cpu"])
        XCTAssertEqual(unknown.first?.suggestion, "container.pools.big.cpus")
        let why = invalidMessage("container:\n  image: i\n  pools:\n    big: { cpu: 4 }\n")
        XCTAssertTrue(why.contains("container.pools.big.cpu"), why)
    }

    // MARK: - Validation

    func testPoolNamesMustBeLabelSafe() {
        for name in ["Big", "-big", "big-", "big_one", "big.one", String(repeating: "a", count: 33)] {
            let why = invalidMessage("container:\n  image: i\n  pools:\n    \"\(name)\": {}\n")
            XCTAssertTrue(why.contains("is not a valid pool name"), "\(name): \(why)")
        }
        XCTAssertNoThrow(try parse("container:\n  image: i\n  pools:\n    a-1: {}\n"))
        XCTAssertNoThrow(try parse("container:\n  image: i\n  pools:\n    \(String(repeating: "a", count: 32)): {}\n"))
    }

    func testAPoolNeedsAnImageFromItselfOrTheSection() {
        let why = invalidMessage("container:\n  pools:\n    a: { labels: [a] }\n")
        XCTAssertTrue(why.contains("container.pools.a.image is required"), why)
        XCTAssertTrue(
            invalidMessage("container:\n  pools:\n    a: { image: \"-x\" }\n").contains("container.pools.a.image"))
    }

    func testAnEmptyPoolsMapIsRejected() {
        XCTAssertTrue(invalidMessage("container:\n  image: i\n  pools: {}\n").contains("at least one pool"))
    }

    func testEachPoolKeyIsCheckedUnderItsOwnPath() {
        let cases: [(pool: String, expected: String)] = [
            ("{ cpus: 0 }", "container.pools.a.cpus must be >= 1"),
            ("{ memory_gb: 1 }", "container.pools.a.memory_gb must be >= 2"),
            ("{ min_idle: -1 }", "container.pools.a.min_idle must be >= 0"),
            ("{ max: 0 }", "container.pools.a.max must be >= 1"),
            ("{ min_idle: 3, max: 2 }", "container.pools.a.min_idle (3) must be <= container.pools.a.max (2)"),
            ("{ platform: linux/riscv64 }", "container.pools.a.platform must be linux/arm64 or linux/amd64"),
            ("{ flags: [\"--cpus\", \"2\"] }", "container.pools.a.flags must not set --cpus"),
            ("{ flags: [\"2g\"] }", "container.pools.a.flags must start with an option"),
            ("{ base_image: \"-bad\" }", "container.pools.a.base_image"),
            ("{ labels: [\"\"] }", "container.pools.a.labels must not contain empty labels"),
        ]
        for (pool, expected) in cases {
            let why = invalidMessage("container:\n  image: i\n  pools:\n    a: \(pool)\n")
            XCTAssertTrue(why.contains(expected), "\(pool): \(why)")
        }
    }

    func testTheSectionKeysAreStillCheckedWithPools() {
        XCTAssertTrue(
            invalidMessage("container:\n  cpus: 0\n  pools:\n    a: { image: i }\n").contains("container.cpus"))
        XCTAssertTrue(
            invalidMessage("container:\n  flags: [\"--rm\"]\n  pools:\n    a: { image: i }\n")
                .contains("container.flags must not set --rm"))
    }

    func testTwoPoolsWithTheSameLabelsAreRejected() {
        let why = invalidMessage(
            "container:\n  image: i\n  pools:\n    a: { labels: [x, Y] }\n    b: { labels: [y, X] }\n")
        XCTAssertTrue(why.contains("container.pools a and b have the same labels"), why)
        XCTAssertTrue(
            invalidMessage("container:\n  image: i\n  pools:\n    a: {}\n    b: {}\n").contains("the same labels"),
            "two catch-all pools cannot be told apart either")
    }

    func testOneImageCannotBeBakedFromTwoBases() {
        let why = invalidMessage(
            "container:\n  image: i\n  pools:\n    a: { labels: [a], base_image: \"ubuntu:24.04\" }\n"
                + "    b: { labels: [b], base_image: \"debian:12\" }\n")
        XCTAssertTrue(why.contains("both run image i but name different base_image values"), why)
    }

    func testPoolFloorsMustFitMaxRunners() {
        let one = invalidMessage("container:\n  image: i\n  pools:\n    a: { min_idle: 11 }\n")
        XCTAssertTrue(one.contains("container.pools.a.min_idle (11) must be <= max_runners (10)"), one)
        let sum = invalidMessage(
            "container:\n  image: i\n  pools:\n    a: { labels: [a], min_idle: 6 }\n    b: { min_idle: 5 }\n")
        XCTAssertTrue(sum.contains("min_idle across"), sum)
        XCTAssertNoThrow(
            try parse("container:\n  image: i\n  pools:\n    a: { labels: [a], min_idle: 5 }\n    b: { min_idle: 5 }\n")
        )
    }

    func testTheStarterTemplateShowsPools() throws {
        XCTAssertNil(try ConfigLoader.parse(ConfigLoader.template()).container)
        XCTAssertTrue(ConfigLoader.template().contains("#   pools:"))
    }

    // MARK: - Editors keep the pools

    private func file(_ yaml: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("container-pools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testTheSnapshotCarriesThePoolsAsWritten() throws {
        let snapshot = try GeneralConfigEditor.snapshot(from: Self.head + Self.twoPools)
        let container = try XCTUnwrap(snapshot.container)
        XCTAssertEqual(container.image, "", "the section names no image of its own")
        XCTAssertEqual(
            container.pools,
            [
                .init(
                    name: "big", image: "kinhin-ci-linux", cpus: 4, memoryGB: 12, labels: ["linux", "big"],
                    flags: ["--shm-size", "2g"], max: 2),
                .init(name: "linux", image: "kinhin-ci-linux", labels: ["linux"], minIdle: 1),
            ],
            "only the keys each pool sets, not the section's defaults")
    }

    func testContainerSectionRewritesKeepEveryPool() throws {
        let url = try file(Self.head + Self.twoPools)
        let before = try XCTUnwrap(ConfigLoader.load(from: url).container)
        _ = try GeneralConfigEditor.setBaseImage("ubuntu:24.04", for: .appleContainer, at: url)
        let after = try XCTUnwrap(ConfigLoader.load(from: url).container)
        XCTAssertEqual(after.baseImage, "ubuntu:24.04")
        XCTAssertEqual(after.pools.map(\.name), before.pools.map(\.name))
        for pool in before.pools {
            var expected = pool
            expected.baseImage = "ubuntu:24.04"
            XCTAssertEqual(
                after.pool(named: pool.name), expected, "pool \(pool.name) inherits the new base, and only that")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            text.contains("image: \"kinhin-ci-linux\"\n  base_image"), "no section image was invented:\n\(text)")
    }

    func testEditingTheContainerSectionKeepsEveryPool() throws {
        let yaml = Self.head + Self.twoPools
        var edited = try XCTUnwrap(GeneralConfigEditor.snapshot(from: yaml).container)
        edited.cpus = 3
        let rewritten = try GeneralConfigEditor.replace(field: .container(edited), in: yaml)
        let container = try XCTUnwrap(ConfigLoader.parse(rewritten).container)
        XCTAssertEqual(container.pool(named: "linux").cpus, 3, "a pool without cpus follows the section")
        XCTAssertEqual(container.pool(named: "big").cpus, 4, "a pool with its own keeps it")
        XCTAssertEqual(container.pool(named: "big").flags, ["--shm-size", "2g"], rewritten)
        XCTAssertEqual(container.pool(named: "big").max, 2, rewritten)
        XCTAssertEqual(container.pool(named: "linux").minIdle, 1, rewritten)
        XCTAssertEqual(try GeneralConfigEditor.snapshot(from: rewritten).container?.pools, edited.pools)
    }

    func testAPoolThatSetsNothingStaysAPool() throws {
        let yaml = Self.head + "container:\n  image: i\n  pools:\n    a: { labels: [a] }\n    b: {}\n"
        let edited = try XCTUnwrap(GeneralConfigEditor.snapshot(from: yaml).container)
        let rewritten = try GeneralConfigEditor.replace(field: .container(edited), in: yaml)
        XCTAssertEqual(try ConfigLoader.parse(rewritten).container?.pools.map(\.name), ["a", "b"], rewritten)
    }

    func testEditingTheSectionLabelsKeepsEveryPool() throws {
        let url = try file(
            Self.head + "container:\n  image: i\n  labels: [linux]\n" + "  pools:\n    a: {}\n"
                + "    b:\n      labels: [linux, big]\n      cpus: 4\n")
        _ = try LabelsConfigEditor.apply(["linux", "arm"], scope: .container, to: url)
        let container = try XCTUnwrap(ConfigLoader.load(from: url).container)
        XCTAssertEqual(container.labels, ["linux", "arm"])
        XCTAssertEqual(container.pool(named: "a").labels, ["linux", "arm"], "a pool without labels inherits them")
        XCTAssertEqual(container.pool(named: "b").labels, ["linux", "big"])
        XCTAssertEqual(container.pool(named: "b").cpus, 4)
    }
}
