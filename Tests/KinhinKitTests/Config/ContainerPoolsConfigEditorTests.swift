import XCTest

@testable import KinhinKit

/// The app's add / edit / remove of a named container pool: what it writes, what it refuses, and that the rest of
/// the file (and every other pool) survives.
final class ContainerPoolsConfigEditorTests: XCTestCase {
    private static let head = """
        accounts:
          - name: github
            forge: github
            scope: "acme"
        # keep this comment
        labels: [self-hosted, arm64]
        max_runners: 10

        """

    private func file(_ yaml: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pool-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func container(at url: URL) throws -> KinhinConfig.ContainerConfig {
        try XCTUnwrap(ConfigLoader.load(from: url).container)
    }

    // MARK: - Adding

    func testAddingTheFirstPoolKeepsTheSectionKeysAsDefaults() throws {
        let url = try file(Self.head + "container:\n  image: kinhin-ci-linux\n  cpus: 2\n  memory_gb: 7\n")
        try ContainerPoolsConfigEditor.save(
            .init(name: "big", cpus: 4, memoryGB: 12, labels: ["linux", "big"], docker: true, max: 2), replacing: nil,
            at: url)
        let container = try container(at: url)
        let big = try XCTUnwrap(container.pools.first)
        XCTAssertEqual(container.pools.map(\.name), ["big"])
        XCTAssertEqual(big.image, "kinhin-ci-linux", "a pool without an image takes the section's")
        XCTAssertEqual(big.cpus, 4)
        XCTAssertEqual(big.memoryGB, 12)
        XCTAssertEqual(big.labels, ["linux", "big"])
        XCTAssertEqual(big.max, 2)
        XCTAssertTrue(big.docker)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# keep this comment"), "comments outside container: survive:\n\(text)")
        XCTAssertTrue(text.contains("  image: \"kinhin-ci-linux\""), "the section keeps its own image:\n\(text)")
    }

    func testAddingAPoolKeepsTheOthersAsWritten() throws {
        let url = try file(
            Self.head
                + "container:\n  cpus: 2\n  pools:\n    linux: { image: i, labels: [linux], min_idle: 1 }\n"
                + "    gpu:\n      image: g\n      labels: [gpu]\n      flags: [\"--shm-size\", \"2g\"]\n"
                + "      fleet_labels: false\n")
        let before = try XCTUnwrap(ConfigStore.snapshot(at: url)?.container?.pools)
        try ContainerPoolsConfigEditor.save(.init(name: "big", image: "i", labels: ["big"]), replacing: nil, at: url)
        let after = try XCTUnwrap(ConfigStore.snapshot(at: url)?.container?.pools)
        XCTAssertEqual(after.map(\.name), ["big", "gpu", "linux"], "sorted by name, like the loader")
        XCTAssertEqual(after.filter { $0.name != "big" }, before, "the other pools are written back unchanged")
    }

    func testAnInvalidOrTakenNameIsRefusedAndNothingIsWritten() throws {
        let yaml = Self.head + "container:\n  image: i\n  pools:\n    linux: { labels: [linux] }\n"
        let url = try file(yaml)
        for name in ["Big", "-big", "big pool", "", String(repeating: "a", count: 33), "linux"] {
            XCTAssertThrowsError(
                try ContainerPoolsConfigEditor.save(.init(name: name, labels: ["x"]), replacing: nil, at: url), name
            ) { error in
                guard case ConfigEditError.validation = error else { return XCTFail("\(name): \(error)") }
            }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), yaml)
    }

    func testTheLoaderGatesThePool() throws {
        // Same labels as an existing pool: the loader rejects it, so the file is left alone.
        let yaml = Self.head + "container:\n  image: i\n  pools:\n    linux: { labels: [linux] }\n"
        let url = try file(yaml)
        XCTAssertThrowsError(
            try ContainerPoolsConfigEditor.save(.init(name: "other", labels: ["linux"]), replacing: nil, at: url))
        XCTAssertThrowsError(
            try ContainerPoolsConfigEditor.save(
                .init(name: "big", labels: ["big"], flags: ["--cpus", "8"]), replacing: nil, at: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), yaml)
    }

    func testWithoutAContainerSectionThereIsNothingToEdit() throws {
        let url = try file(Self.head)
        XCTAssertThrowsError(
            try ContainerPoolsConfigEditor.save(.init(name: "big", image: "i"), replacing: nil, at: url))
    }

    // MARK: - Editing

    func testEditingReplacesThePoolAndCanRenameIt() throws {
        let url = try file(
            Self.head + "container:\n  image: i\n  pools:\n    linux: { labels: [linux] }\n"
                + "    big: { labels: [big], cpus: 4, fleet_labels: false }\n")
        var big = try XCTUnwrap(ConfigStore.snapshot(at: url)?.container?.pools.first { $0.name == "big" })
        big.name = "large"
        big.cpus = 6
        big.max = 1
        try ContainerPoolsConfigEditor.save(big, replacing: "big", at: url)
        let container = try container(at: url)
        XCTAssertEqual(container.pools.map(\.name), ["large", "linux"])
        XCTAssertEqual(container.pool(named: "large").cpus, 6)
        XCTAssertEqual(container.pool(named: "large").max, 1)
        XCTAssertEqual(container.pool(named: "large").fleetLabels, false, "keys the form does not show are kept")
    }

    func testEditingAPoolThatIsGoneIsRefused() throws {
        let url = try file(Self.head + "container:\n  image: i\n  pools:\n    linux: { labels: [linux] }\n")
        XCTAssertThrowsError(
            try ContainerPoolsConfigEditor.save(.init(name: "big"), replacing: "big", at: url)
        ) { error in
            guard case ConfigEditError.unsupported = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Removing

    func testRemovingAPoolKeepsTheOthers() throws {
        let url = try file(
            Self.head + "container:\n  image: i\n  pools:\n    linux: { labels: [linux] }\n    big: { labels: [big] }\n"
        )
        try ContainerPoolsConfigEditor.remove(named: "big", at: url)
        XCTAssertEqual(try container(at: url).pools.map(\.name), ["linux"])
        XCTAssertThrowsError(try ContainerPoolsConfigEditor.remove(named: "big", at: url))
    }

    func testRemovingTheLastPoolLeavesARunnableSection() throws {
        let url = try file(
            Self.head + "container:\n  cpus: 2\n  pools:\n    big: { image: big-image, base_image: \"debian:12\" }\n")
        try ContainerPoolsConfigEditor.remove(named: "big", at: url)
        let container = try container(at: url)
        XCTAssertEqual(container.pools, [])
        XCTAssertEqual(container.image, "big-image", "the section takes the last pool's image")
        XCTAssertEqual(container.baseImage, "debian:12")
        XCTAssertEqual(container.cpus, 2)
    }

    func testRemovingTheLastPoolKeepsTheSectionsOwnImage() throws {
        let section = GeneralConfigEditor.Snapshot.Container(
            image: "own", cpus: 2, memoryGB: 4, baseImage: "ubuntu:24.04",
            pools: [.init(name: "a", image: "a-image", baseImage: "debian:12")])
        let updated = try ContainerPoolsConfigEditor.removing("a", from: section)
        XCTAssertEqual(updated.image, "own")
        XCTAssertEqual(updated.baseImage, "ubuntu:24.04")
    }
}
